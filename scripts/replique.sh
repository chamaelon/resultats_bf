#!/bin/bash
set -euo pipefail

echo "==================================================="
echo " Déploiement de PostgreSQL (Réplica / Esclave)     "
echo "==================================================="

# --- Variables (.env synchronisé via /vagrant, jamais versionné — R7) ---
for FICHIER_ENV in /vagrant/.env /vagrant/app/api/.env; do
  if [ -f "$FICHIER_ENV" ]; then
    set -a
    # shellcheck disable=SC1091
    source <(tr -d '\r' < "$FICHIER_ENV")
    set +a
  fi
done

# ==========================================
# 0. CONFIGURATION ET VARIABLES
# ==========================================
FICHIER_NOEUDS="/vagrant/config/noeuds.yml"

PORT_DB=$(echo "${PG_PORT:-5432}" | tr -d '\r')
APP_DB="${PG_DB:-postgres}"
APP_USER="${PG_USER:-postgres}"
PG_REPLICATION_USER="${PG_REPLICATION_USER:-replicateur}"
if [ -z "${PG_REPLICATION_PASSWORD:-}" ]; then
  [ -n "${PG_PASSWORD:-}" ] || { echo "❌ PG_PASSWORD absent : impossible de dériver PG_REPLICATION_PASSWORD" >&2; exit 1; }
  PG_REPLICATION_PASSWORD=$(printf '%s' "PG_REPLICATION_PASSWORD:$PG_PASSWORD" | sha256sum | cut -c1-32)
fi

# Réseaux autorisés déduits dynamiquement depuis l'IP de bdd1
IP_BDD1=$(awk '/:nom: bdd1/ {found=1} found && /:ip:/ {print $2; found=0}' /vagrant/config/noeuds.yml | tr -d '\r"')
RESEAU="${IP_BDD1%.*}.0/24"
APP_NETWORK="${APP_NETWORK:-$RESEAU}"
REPLICA_NETWORK="${REPLICA_NETWORK:-$RESEAU}"

# Slot de réplication : garantit que le maître conserve les WAL tant que ce réplica ne les a pas reçus
SLOT_NAME="${SLOT_NAME:-replica_${HOSTNAME//[^a-z0-9]/_}}"

# IP du maître (bdd1) lue dans noeuds.yml (généré par le Vagrantfile)
MASTER_HOST=$(awk '/:nom: bdd1/ {found=1} found && /:ip:/ {print $2; found=0}' "$FICHIER_NOEUDS" | tr -d '\r')
if [ -z "${MASTER_HOST}" ]; then
  echo "❌ Impossible de trouver l'IP de bdd1 dans $FICHIER_NOEUDS" >&2
  exit 1
fi
echo "Maître (bdd1) : ${MASTER_HOST}:${PORT_DB} | Réplica : ${HOSTNAME} | Slot : ${SLOT_NAME}"

# Chaîne de connexion libpq (valeurs entre quotes : sûr même avec des caractères spéciaux)
quote() { local v=${1//\\/\\\\}; v=${v//\'/\\\'}; printf "'%s'" "$v"; }
CONNINFO="host=${MASTER_HOST} port=${PORT_DB} user=$(quote "$PG_REPLICATION_USER") password=$(quote "$PG_REPLICATION_PASSWORD") application_name=${HOSTNAME} connect_timeout=5"

# Exécute une commande de réplication (protocole physique) sur le maître
psql_maitre() { psql "${CONNINFO} replication=true" -v ON_ERROR_STOP=1 "$@"; }

# --- Idempotence (R2) : outils communs ---
SUDO="sudo"

# maj_fichier <destination> <mode> [proprio:groupe]   (contenu lu sur l'entrée standard)
# N'écrit le fichier QUE si son contenu change (idempotence, exigence R2).
# Retour : 0 = fichier modifié, 1 = déjà à jour.
# SUDO vaut "sudo" dans les scripts exécutés en simple utilisateur, vide en root.
maj_fichier() {
  local dest="$1" mode="$2" own="${3:-}" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  # shellcheck disable=SC2086
  if [ -f "$dest" ] && ${SUDO:-} cmp -s "$tmp" "$dest"; then
    ${SUDO:-} chmod "$mode" "$dest"
    if [ -n "$own" ]; then ${SUDO:-} chown "$own" "$dest"; fi
    rm -f "$tmp"; return 1
  fi
  ${SUDO:-} install -m "$mode" "$tmp" "$dest"
  if [ -n "$own" ]; then ${SUDO:-} chown "$own" "$dest"; fi
  rm -f "$tmp"; return 0
}

# ==========================================
# 1. Mise à jour et Installation
# ==========================================
echo "=> Mise à jour des paquets et installation..."
sudo apt-get update -y
sudo apt-get install -y postgresql postgresql-contrib ufw

# ==========================================
# 2. Configuration du Pare-feu (UFW)
# ==========================================
echo "=> Configuration du pare-feu UFW..."
sudo ufw allow ssh
sudo ufw allow from "${APP_NETWORK}" to any port "${PORT_DB}" proto tcp
sudo ufw allow from "${REPLICA_NETWORK}" to any port "${PORT_DB}" proto tcp
sudo ufw --force enable

# ==========================================
# 3. Informations sur le cluster local (Debian/Ubuntu)
# ==========================================
# Colonnes de pg_lsclusters : Ver Cluster Port Status Owner Data-directory Log
read -r PG_VER PG_CLUSTER _ _ _ DATADIR _ < <(pg_lsclusters -h)
UNITE="postgresql@${PG_VER}-${PG_CLUSTER}"
CONF_DIR="/etc/postgresql/${PG_VER}/${PG_CLUSTER}"
echo "Cluster local : ${PG_VER}/${PG_CLUSTER} (${DATADIR})"

# ==========================================
# 4. Attente du maître et test des accès de réplication
# ==========================================
echo "=> Attente du maître ${MASTER_HOST}:${PORT_DB} (bdd1 doit être provisionnée)..."
MAITRE_OK=0
for _ in $(seq 1 60); do
  if psql_maitre -tAc "IDENTIFY_SYSTEM" >/dev/null 2>&1; then MAITRE_OK=1; break; fi
  sleep 2
done
if [ "$MAITRE_OK" -ne 1 ]; then
  echo "❌ Connexion de réplication impossible vers le maître. Détail :" >&2
  psql_maitre -tAc "IDENTIFY_SYSTEM" >&2 || true
  echo "   Vérifiez : 'vagrant up bdd1', le rôle ${PG_REPLICATION_USER}, pg_hba.conf et le pare-feu du maître." >&2
  exit 1
fi
echo "   ✅ Le maître accepte les connexions de réplication"

# ==========================================
# 5. Clonage du maître (pg_basebackup)
# ==========================================
# Idempotence : si ce cluster est déjà un réplica (standby.signal), on ne reclone pas,
# sauf demande explicite : REPLIQUE_RECLONER=1 vagrant provision bdd2
#
# GARDE ANTI-DESTRUCTION : après une bascule (scénario V4), bdd2 est promu : le fichier
# standby.signal a disparu et la base contient les données. Rejouer ce script reclonerait
# alors bdd1 PAR-DESSUS bdd2 et détruirait les écritures faites depuis la promotion.
# Une base neuve (cluster Debian vide) ne contient pas la table : le 1er clonage reste normal.
PORT_CLUSTER=$(pg_lsclusters -h | awk 'NR==1{print $3}')
base_promue() {
  local p r
  for p in "${PORT_DB}" "${PORT_CLUSTER:-5432}" 5432; do
    r=$(sudo -u postgres psql -p "$p" -d "${APP_DB}" -tAc "SELECT to_regclass('public.resultats') IS NOT NULL" 2>/dev/null || true)
    [ "$r" = "t" ] && return 0
  done
  return 1
}

CLONE=0
if [ -f "${DATADIR}/standby.signal" ] && [ "${REPLIQUE_RECLONER:-0}" != "1" ]; then
  echo "=> Ce serveur est déjà un réplica : pas de reclonage (REPLIQUE_RECLONER=1 pour forcer)."
elif [ ! -f "${DATADIR}/standby.signal" ] && [ "${REPLIQUE_RECLONER:-0}" != "1" ] && base_promue; then
  echo "⚠️  ${HOSTNAME} n'est plus un réplica (pas de standby.signal) mais contient la table resultats :"
  echo "    il a sans doute été promu (bascule). Reclonage REFUSÉ pour ne pas détruire ses données."
  echo "    Pour le refaire réplica de l'ACTUEL primaire : REPLIQUE_RECLONER=1 vagrant provision ${HOSTNAME}"
  echo "    (le maître visé est lu dans noeuds.yml : bdd1). Aucune modification effectuée."
  exit 0
else
  CLONE=1
  echo "=> Arrêt de PostgreSQL et purge du cluster local (initialisé indépendamment du maître)..."
  sudo systemctl stop "${UNITE}" || true
  sudo find "${DATADIR}" -mindepth 1 -delete

  # Slot éventuellement laissé par un clonage précédent (inactif car ce serveur est arrêté)
  psql_maitre -c "DROP_REPLICATION_SLOT ${SLOT_NAME}" >/dev/null 2>&1 || true

  echo "=> Copie de base depuis le maître (pg_basebackup)... Cela peut prendre un moment."
  # -R : crée standby.signal + primary_conninfo ; -C -S : crée le slot ; -X stream : WAL en flux
  sudo -u postgres pg_basebackup -d "${CONNINFO}" -D "${DATADIR}" \
    -X stream -C -S "${SLOT_NAME}" -R -v
fi

# ==========================================
# 6. Configuration du réplica
# ==========================================
echo "=> Configuration du réplica (conf.d + pg_hba.conf)..."
sudo mkdir -p "${CONF_DIR}/conf.d"
CONF_MODIFIEE=0
if maj_fichier "${CONF_DIR}/conf.d/50-replique.conf" 0644 <<EOF
# Généré par replique.sh
listen_addresses = '*'
port = ${PORT_DB}
hot_standby = on             # lectures autorisées sur le réplica
hot_standby_feedback = on    # évite l'annulation des requêtes longues par le maître
EOF
then CONF_MODIFIEE=1; fi

# pg_hba.conf n'est pas copié par pg_basebackup (il est dans /etc) : on le renseigne ici.
PGHBA="${CONF_DIR}/pg_hba.conf"
# Bloc reconstruit puis comparé : pg_hba.conf n'est réécrit que s'il change.
HBA_NOUVEAU=$(mktemp)
# shellcheck disable=SC2024   # redirection volontairement faite en simple utilisateur (fichier temporaire)
sudo sed "/# resultats-bf : début/,/# resultats-bf : fin/d" "${PGHBA}" > "$HBA_NOUVEAU"
{
  echo "# resultats-bf : début"
  echo "host    ${APP_DB}      ${APP_USER}                 ${APP_NETWORK}        md5"
  echo "host    replication       ${PG_REPLICATION_USER}     ${REPLICA_NETWORK}    md5"
  echo "# resultats-bf : fin"
} >> "$HBA_NOUVEAU"
HBA_MODIFIE=0
if ! sudo cmp -s "$HBA_NOUVEAU" "${PGHBA}"; then
  sudo tee "${PGHBA}" < "$HBA_NOUVEAU" > /dev/null    # tee conserve propriétaire et droits
  HBA_MODIFIE=1
fi
rm -f "$HBA_NOUVEAU"

echo "=> Démarrage de PostgreSQL..."
sudo systemctl enable "${UNITE}" > /dev/null 2>&1 || true
# Redémarrage seulement après un clonage, un changement de paramètres, ou si le service est
# arrêté ; un simple changement de pg_hba.conf ne demande qu'un rechargement.
if [ "$CLONE" -eq 1 ] || [ "$CONF_MODIFIEE" -eq 1 ] || ! sudo systemctl is-active --quiet "${UNITE}"; then
  sudo systemctl restart "${UNITE}"
  echo "   PostgreSQL (re)démarré"
elif [ "$HBA_MODIFIE" -eq 1 ]; then
  sudo systemctl reload "${UNITE}"
  echo "   pg_hba.conf rechargé (sans redémarrage)"
else
  echo "   configuration inchangée : aucun redémarrage"
fi

for _ in $(seq 1 60); do
  if sudo -u postgres pg_isready -q -p "${PORT_DB}"; then break; fi
  sleep 1
done

# ==========================================
# 7. Vérifications (non bloquantes)
# ==========================================
psql_local() { sudo -u postgres psql -p "${PORT_DB}" -tAc "$1"; }

echo "=> Vérification de la réplication..."
EN_RECOVERY=$(psql_local "SELECT pg_is_in_recovery();" 2>/dev/null || echo "?")
if [ "$EN_RECOVERY" = "t" ]; then
  echo "   ✅ Mode réplica actif (pg_is_in_recovery = true)"
else
  echo "   ⚠️  Ce serveur n'est pas en mode réplica (valeur : ${EN_RECOVERY})"
fi

STATUT="?"
for _ in $(seq 1 30); do
  STATUT=$(psql_local "SELECT status FROM pg_stat_wal_receiver;" 2>/dev/null || echo "?")
  [ "$STATUT" = "streaming" ] && break
  sleep 1
done
if [ "$STATUT" = "streaming" ]; then
  echo "   ✅ Réception des WAL en flux depuis ${MASTER_HOST} (streaming)"
else
  echo "   ⚠️  WAL receiver : '${STATUT}' — voir : sudo journalctl -u ${UNITE} -n 50"
fi

NB=$(sudo -u postgres psql -p "${PORT_DB}" -d "${APP_DB}" -tAc "SELECT count(*) FROM resultats;" 2>/dev/null || echo "n/a")
echo "   Lignes de la table 'resultats' répliquées : ${NB}"

echo "==================================================="
echo "✅ Réplica prêt ! (lecture seule)"
echo "Maître : ${MASTER_HOST}:${PORT_DB} | Réplica : ${HOSTNAME} | Slot : ${SLOT_NAME}"
echo "Sur le maître : SELECT client_addr, state, sync_state FROM pg_stat_replication;"
echo "Promotion manuelle : sudo -u postgres psql -c 'SELECT pg_promote();'"
echo "==================================================="