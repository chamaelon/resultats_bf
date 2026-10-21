#!/bin/bash
set -euo pipefail

echo "==================================================="
echo " Déploiement de PostgreSQL (Réplica / Esclave)     "
echo "==================================================="

# --- Variables (.env synchronisé via /vagrant, jamais versionné — R7) ---
if [ -f /vagrant/app/api/.env ]; then
  set -a
  # shellcheck disable=SC1091
  source <(tr -d '\r' < /vagrant/app/api/.env)
  set +a
fi

# ==========================================
# 0. CONFIGURATION ET VARIABLES
# ==========================================
FICHIER_NOEUDS="/vagrant/config/noeuds.yml"

PORT_DB=$(echo "${PG_PORT:-5432}" | tr -d '\r')
APP_DB="${PG_DB:-postgres}"
APP_USER="${PG_USER:-postgres}"
PG_REPLICATION_USER="${PG_REPLICATION_USER:-replicateur}"
PG_REPLICATION_PASSWORD="${PG_REPLICATION_PASSWORD:-postgres}"

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
if [ -f "${DATADIR}/standby.signal" ] && [ "${REPLIQUE_RECLONER:-0}" != "1" ]; then
  echo "=> Ce serveur est déjà un réplica : pas de reclonage (REPLIQUE_RECLONER=1 pour forcer)."
else
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
sudo tee "${CONF_DIR}/conf.d/50-replique.conf" > /dev/null <<EOF
# Généré par replique.sh
listen_addresses = '*'
port = ${PORT_DB}
hot_standby = on             # lectures autorisées sur le réplica
hot_standby_feedback = on    # évite l'annulation des requêtes longues par le maître
EOF

# pg_hba.conf n'est pas copié par pg_basebackup (il est dans /etc) : on le renseigne ici.
PGHBA="${CONF_DIR}/pg_hba.conf"
sudo sed -i "/# resultats-bf : début/,/# resultats-bf : fin/d" "${PGHBA}"
{
  echo "# resultats-bf : début"
  echo "host    ${APP_DB}      ${APP_USER}                 ${APP_NETWORK}        md5"
  echo "host    replication       ${PG_REPLICATION_USER}     ${REPLICA_NETWORK}    md5"
  echo "# resultats-bf : fin"
} | sudo tee -a "${PGHBA}" > /dev/null

echo "=> Démarrage de PostgreSQL..."
sudo systemctl enable "${UNITE}" > /dev/null 2>&1 || true
sudo systemctl restart "${UNITE}"

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

NB=$(sudo -u postgres psql -p "${PORT_DB}" -d "${APP_DB}" -tAc "SELECT count(*) FROM resultat;" 2>/dev/null || echo "n/a")
echo "   Lignes de la table 'resultat' répliquées : ${NB}"

echo "==================================================="
echo "✅ Réplica prêt ! (lecture seule)"
echo "Maître : ${MASTER_HOST}:${PORT_DB} | Réplica : ${HOSTNAME} | Slot : ${SLOT_NAME}"
echo "Sur le maître : SELECT client_addr, state, sync_state FROM pg_stat_replication;"
echo "Promotion manuelle : sudo -u postgres psql -c 'SELECT pg_promote();'"
echo "==================================================="