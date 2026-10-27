#!/bin/bash
# =============================================================================
#  bdd2.sh — Provisionnement du RÉPLICA PostgreSQL (VM bdd2, esclave de bdd1)
#
#  Clone bdd1 avec pg_basebackup (réplication en flux + slot dédié), configure le réplica en
#  lecture seule (hot_standby), pg_hba.conf, pare-feu et exporter Prometheus (port 9187).
#
#  IDEMPOTENT :
#   - déjà réplica (standby.signal) : AUCUN reclonage, aucun redémarrage inutile ;
#   - garde anti-destruction : un bdd2 PROMU (après la bascule du scénario V4) n'est jamais
#     écrasé ; pour le refaire réplica : REPLIQUE_RECLONER=1 vagrant provision bdd2 ;
#   - paramètres et pg_hba.conf comparés avant écriture, rechargement sans redémarrage.
#
#  - PG_REPLICATION_PASSWORD absent du .env => dérivé de PG_PASSWORD (même valeur que bdd1).
#  - bdd1 doit être provisionnée d'abord (le script l'attend jusqu'à 2 minutes).
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
#  Socle commun (identique dans tous les scripts de provisionnement)
# ---------------------------------------------------------------------------
# Exécution en root (Vagrant lance déjà les scripts en root ; sinon on se relance via sudo)
[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"
export DEBIAN_FRONTEND=noninteractive
SUDO=""

# Le .env est lu comme du TEXTE (jamais exécuté : un mot de passe contenant $ ; & ( ) ne casse
# rien et ne peut rien lancer). Une variable déjà présente dans l'environnement reste prioritaire.
charger_env() {
  local f="$1" l k v
  [ -r "$f" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"
    case "$l" in ''|'#'*) continue ;; esac
    l="${l#export }"
    case "$l" in *=*) ;; *) continue ;; esac
    k="${l%%=*}"; v="${l#*=}"
    k="${k//[[:space:]]/}"
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
    [ -n "${!k+x}" ] || export "$k=$v"
  done < "$f"
}
charger_env /vagrant/app/api/.env      # .env de l'application
charger_env /vagrant/.env              # .env à la racine du dépôt (même niveau que le Vagrantfile)

# Secret absent du .env : dérivé de PG_PASSWORD (même valeur sur toutes les VM, rien dans le dépôt).
secret_defaut() {   # secret_defaut NOM
  local nom="$1"
  [ -z "${!nom:-}" ] || return 0
  [ -n "${PG_PASSWORD:-}" ] || { echo "❌ $nom et PG_PASSWORD absents du .env : impossible de dériver $nom" >&2; exit 1; }
  printf -v "$nom" '%s' "$(printf '%s' "$nom:$PG_PASSWORD" | sha256sum | cut -c1-32)"
  # shellcheck disable=SC2163
  export "$nom"
  echo "⚠️  $nom absent du .env : valeur dérivée de PG_PASSWORD (identique sur toutes les VM). Définissez-le dans .env pour la fixer." >&2
}

# Valeur entre guillemets pour redis.conf / fichiers d'environnement systemd
envq() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"; }

# maj_fichier <destination> <mode> [proprio:groupe]   (contenu lu sur l'entrée standard)
# N'écrit le fichier QUE si son contenu change. Retour : 0 = modifié, 1 = déjà à jour.
maj_fichier() {
  local dest="$1" mode="$2" own="${3:-}" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    chmod "$mode" "$dest"
    if [ -n "$own" ]; then chown "$own" "$dest"; fi
    rm -f "$tmp"; return 1
  fi
  install -m "$mode" "$tmp" "$dest"
  if [ -n "$own" ]; then chown "$own" "$dest"; fi
  rm -f "$tmp"; return 0
}

# Installe SEULEMENT les paquets manquants ; "apt-get update" n'est lancé que s'il y en a.
paquet_present() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }
apt_installer() {
  local manquants=() p
  for p in "$@"; do paquet_present "$p" || manquants+=("$p"); done
  [ "${#manquants[@]}" -gt 0 ] || return 0
  echo "=> Installation : ${manquants[*]}"
  apt-get update -y -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq ${APT_OPTS:-} "${manquants[@]}"
}

# Lecture de config/noeuds.yml (écrit par le Vagrantfile — source unique de vérité)
FICHIER_NOEUDS="${FICHIER_NOEUDS:-/vagrant/config/noeuds.yml}"
champ_noeud() {   # champ_noeud <nom> <clé> -> valeur (vide si absente)
  [ -r "$FICHIER_NOEUDS" ] || return 0
  tr -d '\r"' < "$FICHIER_NOEUDS" |
    awk -v n="$1" -v k=":$2:" '$1=="-" && $2==":nom:" {cur=$3; next} $1==k && cur==n {print $2; exit}'
}
noeud_ip() { champ_noeud "$1" ip; }

echo "==================================================="
echo " Déploiement de PostgreSQL (Réplica / Esclave $(hostname))"
echo "==================================================="

# ==========================================
# 0. CONFIGURATION ET VARIABLES
# ==========================================
PORT_DB=$(echo "${PG_PORT:-5432}" | tr -d '\r')
APP_DB="${PG_DB:-postgres}"
APP_USER="${PG_USER:-postgres}"
PG_REPLICATION_USER="${PG_REPLICATION_USER:-replicateur}"
: "${PG_PASSWORD:?PG_PASSWORD absent : définissez-le dans le .env (racine du dépôt ou app/api/.env)}"
secret_defaut PG_REPLICATION_PASSWORD

# IP du maître (bdd1) lue dans noeuds.yml (généré par le Vagrantfile) ; réseaux déduits de cette IP
MASTER_HOST=$(noeud_ip bdd1)
if [ -z "${MASTER_HOST}" ]; then
  echo "❌ Impossible de trouver l'IP de bdd1 dans $FICHIER_NOEUDS" >&2
  exit 1
fi
RESEAU="${MASTER_HOST%.*}.0/24"
APP_NETWORK="${APP_NETWORK:-$RESEAU}"
REPLICA_NETWORK="${REPLICA_NETWORK:-$RESEAU}"
IP_OBS=$(noeud_ip obs || true)
HOSTNAME="${HOSTNAME:-$(hostname)}"

# Slot de réplication : garantit que le maître conserve les WAL tant que ce réplica ne les a pas reçus
SLOT_NAME="${SLOT_NAME:-replica_${HOSTNAME//[^a-z0-9]/_}}"

# Supervision (exporter Prometheus) : même rôle que sur bdd1 (créé là-bas, répliqué ici)
PG_EXPORTER_USER="${PG_EXPORTER_USER:-exporter_prom}"
PG_EXPORTER_PASSWORD="${PG_EXPORTER_PASSWORD:-$(printf '%s' "exporter:$PG_PASSWORD" | sha256sum | cut -c1-32)}"
PORT_EXPORTER=9187

echo "Maître (bdd1) : ${MASTER_HOST}:${PORT_DB} | Réplica : ${HOSTNAME} | Slot : ${SLOT_NAME}"

# Chaîne de connexion libpq (valeurs entre quotes : sûr même avec des caractères spéciaux)
quote() { local v=${1//\\/\\\\}; v=${v//\'/\\\'}; printf "'%s'" "$v"; }
CONNINFO="host=${MASTER_HOST} port=${PORT_DB} user=$(quote "$PG_REPLICATION_USER") password=$(quote "$PG_REPLICATION_PASSWORD") application_name=${HOSTNAME} connect_timeout=5"

# Exécute une commande de réplication (protocole physique) sur le maître
psql_maitre() { psql "${CONNINFO} replication=true" -v ON_ERROR_STOP=1 "$@"; }

# ==========================================
# 1. Mise à jour et Installation
# ==========================================
apt_installer postgresql postgresql-contrib ufw
# L'exporter est facultatif : son absence ne doit pas bloquer le réplica
if ! apt_installer prometheus-postgres-exporter; then
  echo "⚠️  prometheus-postgres-exporter indisponible : pas de métriques PostgreSQL dans Grafana"
fi

# ==========================================
# 2. Configuration du Pare-feu (UFW)
# ==========================================
echo "=> Configuration du pare-feu UFW..."
ufw allow ssh
ufw allow from "${APP_NETWORK}" to any port "${PORT_DB}" proto tcp
ufw allow from "${REPLICA_NETWORK}" to any port "${PORT_DB}" proto tcp
if [ -n "$IP_OBS" ]; then ufw allow from "$IP_OBS" to any port "$PORT_EXPORTER" proto tcp; fi
ufw --force enable

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
  systemctl stop "${UNITE}" || true
  find "${DATADIR}" -mindepth 1 -delete

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
# Généré par bdd2.sh
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
sed "/# resultats-bf : début/,/# resultats-bf : fin/d" "${PGHBA}" > "$HBA_NOUVEAU"
{
  echo "# resultats-bf : début"
  echo "host    ${APP_DB}      ${APP_USER}                 ${APP_NETWORK}        md5"
  echo "host    replication       ${PG_REPLICATION_USER}     ${REPLICA_NETWORK}    md5"
  echo "# resultats-bf : fin"
} >> "$HBA_NOUVEAU"
HBA_MODIFIE=0
if ! cmp -s "$HBA_NOUVEAU" "${PGHBA}"; then
  tee "${PGHBA}" < "$HBA_NOUVEAU" > /dev/null    # tee conserve propriétaire et droits
  HBA_MODIFIE=1
fi
rm -f "$HBA_NOUVEAU"

echo "=> Démarrage de PostgreSQL..."
systemctl enable "${UNITE}" > /dev/null 2>&1 || true
# Redémarrage seulement après un clonage, un changement de paramètres, ou si le service est
# arrêté ; un simple changement de pg_hba.conf ne demande qu'un rechargement.
if [ "$CLONE" -eq 1 ] || [ "$CONF_MODIFIEE" -eq 1 ] || ! systemctl is-active --quiet "${UNITE}"; then
  systemctl restart "${UNITE}"
  echo "   PostgreSQL (re)démarré"
elif [ "$HBA_MODIFIE" -eq 1 ]; then
  systemctl reload "${UNITE}"
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

echo "=> Exporter Prometheus PostgreSQL (port ${PORT_EXPORTER})..."
if paquet_present prometheus-postgres-exporter; then
  EXPORTER_MODIFIE=0
  if maj_fichier /etc/default/prometheus-postgres-exporter 0640 <<EOF
# Généré par bdd2.sh — ne pas éditer à la main
DATA_SOURCE_NAME="postgresql://${PG_EXPORTER_USER}:${PG_EXPORTER_PASSWORD}@127.0.0.1:${PORT_DB}/${APP_DB}?sslmode=disable"
ARGS="--web.listen-address=:${PORT_EXPORTER}"
EOF
  then EXPORTER_MODIFIE=1; fi
  chgrp prometheus /etc/default/prometheus-postgres-exporter 2>/dev/null || true
  systemctl enable prometheus-postgres-exporter >/dev/null 2>&1 || true
  if [ "$EXPORTER_MODIFIE" -eq 1 ] || ! systemctl is-active --quiet prometheus-postgres-exporter; then
    systemctl restart prometheus-postgres-exporter || echo "   ⚠️  prometheus-postgres-exporter n'a pas démarré"
  fi
  sleep 2
  if curl -fs "http://127.0.0.1:${PORT_EXPORTER}/metrics" 2>/dev/null | grep -q '^pg_up 1'; then
    echo "   ✅ Exporter opérationnel (pg_up = 1)"
  else
    echo "   ⚠️  Exporter sans connexion : le rôle ${PG_EXPORTER_USER} est créé sur bdd1 et se réplique ici (bdd1 provisionnée ?)"
  fi
fi

echo "==================================================="
echo "✅ Réplica prêt ! (lecture seule)"
echo "Maître : ${MASTER_HOST}:${PORT_DB} | Réplica : ${HOSTNAME} | Slot : ${SLOT_NAME}"
echo "Sur le maître : SELECT client_addr, state, sync_state FROM pg_stat_replication;"
echo "Promotion manuelle : sudo -u postgres psql -c 'SELECT pg_promote();'"
echo "==================================================="