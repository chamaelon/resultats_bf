#!/bin/bash
set -euo pipefail

echo "==================================================="
echo " Déploiement de la base de données PostgreSQL (Maître) "
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
# 0. CONFIGURATION ET VARIABLES GLOBLALES
# ==========================================
# Chemins d'accès
DOSSIER_SOURCE="${DOSSIER_SOURCE:-/vagrant/app/database}"
FICHIER_SCHEMA="${FICHIER_SCHEMA:-$DOSSIER_SOURCE/schema.sql}"
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
: "${PG_PASSWORD:?PG_PASSWORD absent : définissez-le dans le .env à la racine du dépôt}"
PGPASSWORD="$PG_PASSWORD"
PGTABLE="resultats"  # Table attendue par l'API et le sujet

# Identifiants (Réplication)
PG_REPLICATION_USER="${PG_REPLICATION_USER:-replicateur}"
if [ -z "${PG_REPLICATION_PASSWORD:-}" ]; then
  PG_REPLICATION_PASSWORD=$(printf '%s' "PG_REPLICATION_PASSWORD:$PG_PASSWORD" | sha256sum | cut -c1-32)
fi

# Autres variables (ex: pour Keepalived / VIP)

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
# Port réellement utilisé AVANT toute modification. Au 1er passage c'est 5432 ; aux
# suivants c'est PORT_DB (ALTER SYSTEM l'a écrit dans postgresql.auto.conf, que
# pg_lsclusters ne lit pas toujours) : on interroge donc les ports candidats.
PORT_CLUSTER=$(pg_lsclusters -h | awk 'NR==1{print $3}')
port_actif() {
  local p
  for p in "${PORT_DB}" "${PORT_CLUSTER:-}" 5432; do
    [ -n "$p" ] || continue
    if sudo -u postgres pg_isready -q -p "$p"; then echo "$p"; return 0; fi
  done
  return 1
}
sudo systemctl start postgresql          # sans effet si déjà démarré
PORT_ACTUEL=""
for _ in $(seq 1 30); do
  PORT_ACTUEL=$(port_actif || true)
  [ -n "$PORT_ACTUEL" ] && break
  sleep 1
done
[ -n "$PORT_ACTUEL" ] || { echo "❌ PostgreSQL ne répond sur aucun port connu : journalctl -u postgresql" >&2; exit 1; }

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

# Le bloc géré par ce script est reconstruit puis comparé : pg_hba.conf n'est réécrit
# que s'il change (le sed + "tee -a" d'origine le réécrivait à chaque rejeu).
HBA_NOUVEAU=$(mktemp)
# shellcheck disable=SC2024   # la redirection vers le fichier temporaire se fait volontairement en simple utilisateur
sudo sed "/# resultats-bf : début/,/# resultats-bf : fin/d" "${PGHBA}" > "$HBA_NOUVEAU"
{
  echo "# resultats-bf : début"
  echo "host    ${PGDATABASE}      ${PGUSER}                 ${APP_NETWORK}        md5"
  echo "host    replication       ${PG_REPLICATION_USER}     ${REPLICA_NETWORK}    md5"
  echo "# resultats-bf : fin"
} >> "$HBA_NOUVEAU"
if sudo cmp -s "$HBA_NOUVEAU" "${PGHBA}"; then
  echo "   pg_hba.conf déjà à jour"
else
  sudo tee "${PGHBA}" < "$HBA_NOUVEAU" > /dev/null    # tee conserve propriétaire et droits
  echo "   pg_hba.conf mis à jour"
fi
rm -f "$HBA_NOUVEAU"

# Application de la configuration : rechargement (SIGHUP) d'abord, puis redémarrage
# UNIQUEMENT si un paramètre l'exige (pending_restart). Au 1er passage listen_addresses
# impose un redémarrage ; aux suivants, rien ne bouge et le service reste disponible.
echo "=> Application de la configuration..."
sudo -u postgres psql -p "${PORT_ACTUEL}" -tAqc "SELECT pg_reload_conf();" > /dev/null
sleep 1
A_REDEMARRER=$(sudo -u postgres psql -p "${PORT_ACTUEL}" -tAc "SELECT count(*) FROM pg_settings WHERE pending_restart;")
if [ "${A_REDEMARRER:-0}" -gt 0 ] || [ "${PORT_ACTUEL}" != "${PORT_DB}" ]; then
  echo "   ${A_REDEMARRER} paramètre(s) exigent un redémarrage : redémarrage de PostgreSQL"
  sudo systemctl restart postgresql
else
  echo "   aucun redémarrage nécessaire"
fi
# Attente active que le service réponde sur le port définitif
for _ in $(seq 1 30); do
  if sudo -u postgres pg_isready -q -p "${PORT_DB}"; then break; fi
  sleep 1
done
sudo -u postgres pg_isready -q -p "${PORT_DB}" || { echo "❌ PostgreSQL ne répond pas sur le port ${PORT_DB}" >&2; exit 1; }

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
# CORRECTION : plus de "psql | grep -q" sous pipefail (SIGPIPE possible -> faux négatif)
DB_EXISTS=$(psql_postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${PGDATABASE}'")
if [ "$DB_EXISTS" != "1" ]; then
  sudo -u postgres createdb -p "${PORT_DB}" -O "${PGUSER}" "${PGDATABASE}"
fi

table_existe() {
  psql_base -tAc "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = '${PGTABLE}');"
}

# CORRECTION (idempotence) : le schéma n'est appliqué que si la table n'existe pas,
# sinon 'vagrant provision' échouait sur un CREATE TABLE déjà exécuté.
if [ "$(table_existe)" != "t" ]; then
  if [ -f "$FICHIER_SCHEMA" ]; then
    echo "==> Application du schéma (${FICHIER_SCHEMA})..."
    psql_base -1 -f "$FICHIER_SCHEMA"     # -1 : transaction unique, tout ou rien
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
          psql_base -1 -f "$FICHIER_DONNEES"    # -1 : tout ou rien, sinon un chargement interrompu ne serait jamais repris
      else
          echo "⚠️ AVERTISSEMENT : Fichier de données introuvable ($FICHIER_DONNEES)"
      fi
    else
      echo "==> La base contient déjà ${NB_LIGNES} lignes. Peuplement ignoré (Idempotence respectée)."
    fi
else
    echo "⚠️️ AVERTISSEMENT : La table '${PGTABLE}' n'existe pas. Impossible de vérifier les données."
fi

# ==========================================
# 8. Vérifications (non bloquantes)
# ==========================================
echo "=> Vérification de la connexion applicative (TCP + mot de passe)..."
if PGPASSWORD="${PGPASSWORD}" psql -h 127.0.0.1 -p "${PORT_DB}" -U "${PGUSER}" -d "${PGDATABASE}" -tAc "SELECT 'ok'" >/dev/null 2>&1; then
  echo "   ✅ Connexion ${PGUSER}@${PGDATABASE} OK"
else
  echo "   ⚠️  Connexion applicative en échec (voir /var/log/postgresql/)"
fi
echo "   Écoute réseau :"; ss -ltn | grep ":${PORT_DB} " || true

echo "==================================================="
echo "✅ Serveur de Base de Données prêt !"
echo "Base : ${PGDATABASE} | Port : ${PORT_DB} | Accès autorisé depuis : ${APP_NETWORK}"
echo "Réplication autorisée pour l'utilisateur : ${PG_REPLICATION_USER}"
echo "==================================================="