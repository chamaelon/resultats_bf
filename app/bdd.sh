#!/bin/bash
set -euo pipefail

echo "==================================================="
echo " Déploiement de la base de données PostgreSQL (Maître) "
echo "==================================================="

# --- Variables (.env synchronisé via /vagrant, jamais versionné — R7) ---
if [ -f /vagrant/app/api/.env ]; then
  set -a
  # shellcheck disable=SC1091
  source <(tr -d '\r' < /vagrant/app/api/.env)
  set +a
fi

# ==========================================
# 0. CONFIGURATION ET VARIABLES GLOBLALES
# ==========================================
# Chemins d'accès
DOSSIER_SOURCE="${DOSSIER_SOURCE:-/vagrant/app/database}"
FICHIER_SCHEMA="${FICHIER_SCHEMA:-$DOSSIER_SOURCE/schemas/resultats.sql}"
FICHIER_DONNEES="${FICHIER_DONNEES:-$DOSSIER_SOURCE/schemas/data.sql}"

# Paramètres réseau
PORT_DB="${PG_PORT:-5432}"
PORT_DB=$(echo "$PORT_DB" | tr -d '\r')
# Réseaux autorisés déduits dynamiquement depuis l'IP de bdd1
IP_BDD1=$(awk '/:nom: bdd1/ {found=1} found && /:ip:/ {print $2; found=0}' /vagrant/config/noeuds.yml | tr -d '\r"')
RESEAU="${IP_BDD1%.*}.0/24"
APP_NETWORK="${APP_NETWORK:-$RESEAU}"          # API Node.js
REPLICA_NETWORK="${REPLICA_NETWORK:-$RESEAU}"  # nœuds réplicas

# Identifiants (Application)
# CORRECTION : PG_DB du .env était ignoré (seul PGDATABASE était lu)
PGDATABASE="${PG_DB:-${PGDATABASE:-postgres}}"
PGUSER="${PG_USER:-postgres}"
PGPASSWORD="${PG_PASSWORD:-postgres}"
PGTABLE="resultat"  # Nom de la table principale (pour peuplement)

# Identifiants (Réplication)
PG_REPLICATION_USER="${PG_REPLICATION_USER:-replicateur}"
PG_REPLICATION_PASSWORD="${PG_REPLICATION_PASSWORD:-postgres}"

# Autres variables (ex: pour Keepalived / VIP)
VRRP_AUTH_PASS="${VRRP_AUTH_PASS:-postgres}"

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

