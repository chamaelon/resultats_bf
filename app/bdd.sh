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
FICHIER_SCHEMA="${FICHIER_SCHEMA:-$DOSSIER_SOURCE/resultats.sql}"
FICHIER_DONNEES="${FICHIER_DONNEES:-$DOSSIER_SOURCE/data.sql}"

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

# ==========================================
# 3. Configuration de PostgreSQL (Idempotent via SQL)
# ==========================================
# Port réellement utilisé AVANT redémarrage (5432 au 1er passage, PORT_DB aux suivants)
PORT_ACTUEL=$(pg_lsclusters -h | awk 'NR==1{print $3}')
PORT_ACTUEL="${PORT_ACTUEL:-5432}"

echo "=> Configuration des paramètres du serveur (ALTER SYSTEM)..."
sudo -u postgres psql -p "${PORT_ACTUEL}" -v ON_ERROR_STOP=1 <<SQL
ALTER SYSTEM SET listen_addresses = '*';
ALTER SYSTEM SET port = '${PORT_DB}';
-- Prérequis pour la réplication en flux
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET max_wal_senders = '10';
ALTER SYSTEM SET max_replication_slots = '10';
ALTER SYSTEM SET hot_standby = 'on';
SQL

# ==========================================
# 4. Configuration des accès réseau (pg_hba.conf)
# ==========================================
echo "=> Configuration des autorisations réseau (pg_hba.conf)..."
PGHBA=$(sudo -u postgres psql -p "${PORT_ACTUEL}" -tAc "SHOW hba_file;" | tr -d ' ')

sudo sed -i "/# resultats-bf : début/,/# resultats-bf : fin/d" "${PGHBA}"
{
  echo "# resultats-bf : début"
  echo "host    ${PGDATABASE}      ${PGUSER}                 ${APP_NETWORK}        md5"
  echo "host    replication       ${PG_REPLICATION_USER}     ${REPLICA_NETWORK}    md5"
  echo "# resultats-bf : fin"
} | sudo tee -a "${PGHBA}" > /dev/null

echo "=> Redémarrage de PostgreSQL pour appliquer la configuration..."
sudo systemctl restart postgresql
# Attente active (remplace le "sleep 2") que le service réponde sur le nouveau port
for _ in $(seq 1 30); do
  if sudo -u postgres pg_isready -q -p "${PORT_DB}"; then break; fi
  sleep 1
done

# ==========================================
# 5. Création des Rôles (Applicatif et Réplication)
# ==========================================
echo "=> Configuration des rôles PostgreSQL..."
sudo -u postgres psql -p "${PORT_DB}" -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  CREATE ROLE ${PGUSER} LOGIN PASSWORD '${PGPASSWORD}';
EXCEPTION WHEN duplicate_object THEN
  ALTER ROLE ${PGUSER} PASSWORD '${PGPASSWORD}';
END \$\$;

DO \$\$ BEGIN
  CREATE ROLE ${PG_REPLICATION_USER} REPLICATION LOGIN PASSWORD '${PG_REPLICATION_PASSWORD}';
EXCEPTION WHEN duplicate_object THEN
  ALTER ROLE ${PG_REPLICATION_USER} PASSWORD '${PG_REPLICATION_PASSWORD}';
END \$\$;
SQL

# ==========================================
# 6. Création de la base et application du schéma
# ==========================================
psql_postgres() { sudo -u postgres psql -p "${PORT_DB}" -v ON_ERROR_STOP=1 "$@"; }
psql_base()     { psql_postgres -d "${PGDATABASE}" "$@"; }

echo "=> Vérification et création de la base de données '${PGDATABASE}'..."
DB_EXISTS=$(psql_postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${PGDATABASE}'")
if [ "$DB_EXISTS" != "1" ]; then
  sudo -u postgres createdb -p "${PORT_DB}" -O "${PGUSER}" "${PGDATABASE}"
fi

table_existe() {
  psql_base -tAc "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = '${PGTABLE}');"
}

# le schéma n'est appliqué que si la table n'existe pas
if [ "$(table_existe)" != "t" ]; then
  if [ -f "$FICHIER_SCHEMA" ]; then
    echo "==> Application du schéma (${FICHIER_SCHEMA})..."
    psql_base -f "$FICHIER_SCHEMA"
  else
    echo "⚠️ AVERTISSEMENT : Fichier de schéma introuvable ($FICHIER_SCHEMA)"
  fi
else
  echo "==> Table '${PGTABLE}' déjà présente : schéma non réappliqué."
fi

echo "==> Attribution des droits sur le schéma public..."
psql_base -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${PGUSER};"
psql_base -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${PGUSER};"
psql_base -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${PGUSER};"

# ==========================================
# 7. Peuplement de la base de données (Data)
# ==========================================
# Vérifie si la table existe avant de compter pour éviter une erreur SQL
if [ "$(table_existe)" = "t" ]; then
    NB_LIGNES=$(psql_base -tAc "SELECT count(*) FROM ${PGTABLE};")

    if [ "$NB_LIGNES" -eq 0 ]; then
      if [ -f "$FICHIER_DONNEES" ]; then
          echo "==> Peuplement de la base (${FICHIER_DONNEES})... Cela peut prendre un moment."
          psql_base -f "$FICHIER_DONNEES"
      else
          echo "⚠️ AVERTISSEMENT : Fichier de données introuvable ($FICHIER_DONNEES)"
      fi
    else
      echo "==> La base contient déjà ${NB_LIGNES} lignes. Peuplement ignoré (Idempotence respectée)."
    fi
else
    echo "⚠️️ AVERTISSEMENT : La table '${PGTABLE}' n'existe pas. Impossible de vérifier les données."
fi

