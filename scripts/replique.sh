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

