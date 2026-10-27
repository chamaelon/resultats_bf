#!/bin/bash
# =============================================================================
#  bdd1.sh — Provisionnement de la base de données PRIMAIRE (VM bdd1, PostgreSQL)
#
#  Fait, dans l'ordre : installation de PostgreSQL (dernière version des dépôts de la box),
#  pare-feu, paramètres de réplication en flux, pg_hba.conf, rôles (applicatif, réplication,
#  supervision), base, schéma, droits, peuplement, exporter Prometheus (port 9187).
#
#  IDEMPOTENT : rejoué, il ne change rien — paramètres et pg_hba.conf comparés avant écriture,
#  redémarrage seulement si PostgreSQL l'exige, schéma et données chargés UNE seule fois
#  (table absente / table vide), rôles resynchronisés avec le .env.
#
#  - Secrets : PG_PASSWORD obligatoire ; PG_REPLICATION_PASSWORD absent => dérivé de PG_PASSWORD
#    (même valeur que sur bdd2). Aucun mot de passe n'est écrit dans ce script.
#  - Les mots de passe passent par des variables psql (:'var', format(%I/%L), \gexec) : une
#    apostrophe dans un mot de passe ne casse rien.
#  - Schéma et données : cherchés dans app/api/database/schemas, app/database/schemas,
#    la racine du dépôt (schema.sql / data.sql) et config/ — ou FICHIER_SCHEMA / FICHIER_DONNEES.
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
echo " Déploiement de la base de données PostgreSQL (primaire $(hostname))"
echo "==================================================="

# ==========================================
# 0. CONFIGURATION ET VARIABLES GLOBALES
# ==========================================
PORT_DB=$(echo "${PG_PORT:-5432}" | tr -d '\r')
IP_BDD1=$(noeud_ip bdd1)
[ -n "$IP_BDD1" ] || { echo "❌ Impossible de trouver l'IP de bdd1 dans $FICHIER_NOEUDS" >&2; exit 1; }
RESEAU="${IP_BDD1%.*}.0/24"
APP_NETWORK="${APP_NETWORK:-$RESEAU}"          # API Node.js (tout le /24 : ajouter un serveur n'exige pas de toucher à la base)
REPLICA_NETWORK="${REPLICA_NETWORK:-$RESEAU}"  # nœuds réplicas
IP_OBS=$(noeud_ip obs || true)

PGDATABASE="${PG_DB:-${PGDATABASE:-postgres}}"
PGUSER="${PG_USER:-postgres}"
PGTABLE="resultats"  # Table attendue par l'API et le sujet
PG_REPLICATION_USER="${PG_REPLICATION_USER:-replicateur}"

# Secrets : PG_PASSWORD obligatoire ; celui de la réplication est dérivé s'il manque
: "${PG_PASSWORD:?PG_PASSWORD absent : définissez-le dans le .env (racine du dépôt ou app/api/.env)}"
secret_defaut PG_REPLICATION_PASSWORD
PGPASSWORD="$PG_PASSWORD"

# Supervision (exporter Prometheus) : rôle dédié en lecture seule (pg_monitor)
PG_EXPORTER_USER="${PG_EXPORTER_USER:-exporter_prom}"
PG_EXPORTER_PASSWORD="${PG_EXPORTER_PASSWORD:-$(printf '%s' "exporter:$PG_PASSWORD" | sha256sum | cut -c1-32)}"
PORT_EXPORTER=9187

# Schéma et données : premier fichier trouvé parmi les emplacements usuels
trouver_fichier() { local f; for f in "$@"; do if [ -f "$f" ]; then echo "$f"; return 0; fi; done; return 1; }
FICHIER_SCHEMA="${FICHIER_SCHEMA:-$(trouver_fichier \
  /vagrant/app/database/schema.sql \
  /vagrant/app/api/database/schemas/resultats.sql /vagrant/app/api/database/schemas/schema.sql \
  /vagrant/app/database/schemas/resultats.sql /vagrant/app/database/schemas/schema.sql \
  /vagrant/schema.sql /vagrant/config/schema.sql || true)}"
FICHIER_DONNEES="${FICHIER_DONNEES:-$(trouver_fichier \
  /vagrant/app/database/data.sql \
  /vagrant/app/api/database/schemas/data.sql /vagrant/app/database/schemas/data.sql \
  /vagrant/data.sql /vagrant/config/data.sql || true)}"

# ==========================================
# 1. Mise à jour et Installation
# ==========================================
apt_installer postgresql postgresql-contrib ufw
# L'exporter est facultatif : son absence ne doit pas bloquer la base
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
# 3. Configuration de PostgreSQL (Idempotent via SQL)
# ==========================================
PORT_CLUSTER=$(pg_lsclusters -h | awk 'NR==1{print $3}')
port_actif() {
  local p
  for p in "${PORT_DB}" "${PORT_CLUSTER:-}" 5432; do
    [ -n "$p" ] || continue
    if sudo -u postgres pg_isready -q -p "$p"; then echo "$p"; return 0; fi
  done
  return 1
}
systemctl start postgresql          # sans effet si déjà démarré
PORT_ACTUEL=""
for _ in $(seq 1 30); do
  PORT_ACTUEL=$(port_actif || true)
  [ -n "$PORT_ACTUEL" ] && break
  sleep 1
done
[ -n "$PORT_ACTUEL" ] || { echo "❌ PostgreSQL ne répond sur aucun port connu : journalctl -u postgresql" >&2; exit 1; }

echo "=> Configuration des paramètres du serveur (ALTER SYSTEM)..."
sudo -u postgres psql -p "${PORT_ACTUEL}" -v ON_ERROR_STOP=1 -v port_db="${PORT_DB}" <<'SQL'
ALTER SYSTEM SET listen_addresses = '*';
SELECT format('ALTER SYSTEM SET port = %L', :'port_db') \gexec
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

HBA_NOUVEAU=$(mktemp)
# shellcheck disable=SC2024
sed "/# resultats-bf : début/,/# resultats-bf : fin/d" "${PGHBA}" > "$HBA_NOUVEAU"
{
  echo "# resultats-bf : début"
  echo "host    ${PGDATABASE}      ${PGUSER}                 ${APP_NETWORK}        md5"
  echo "host    replication       ${PG_REPLICATION_USER}     ${REPLICA_NETWORK}    md5"
  echo "# resultats-bf : fin"
} >> "$HBA_NOUVEAU"
if cmp -s "$HBA_NOUVEAU" "${PGHBA}"; then
  echo "   pg_hba.conf déjà à jour"
else
  tee "${PGHBA}" < "$HBA_NOUVEAU" > /dev/null    # tee conserve propriétaire et droits
  echo "   pg_hba.conf mis à jour"
fi
rm -f "$HBA_NOUVEAU"

echo "=> Application de la configuration..."
sudo -u postgres psql -p "${PORT_ACTUEL}" -tAqc "SELECT pg_reload_conf();" > /dev/null
sleep 1
A_REDEMARRER=$(sudo -u postgres psql -p "${PORT_ACTUEL}" -tAc "SELECT count(*) FROM pg_settings WHERE pending_restart;")
if [ "${A_REDEMARRER:-0}" -gt 0 ] || [ "${PORT_ACTUEL}" != "${PORT_DB}" ]; then
  echo "   ${A_REDEMARRER} paramètre(s) exigent un redémarrage : redémarrage de PostgreSQL"
  systemctl restart postgresql
else
  echo "   aucun redémarrage nécessaire"
fi
for _ in $(seq 1 30); do
  if sudo -u postgres pg_isready -q -p "${PORT_DB}"; then break; fi
  sleep 1
done
sudo -u postgres pg_isready -q -p "${PORT_DB}" || { echo "❌ PostgreSQL ne répond pas sur le port ${PORT_DB}" >&2; exit 1; }

# ==========================================
# 5. Création des Rôles (Applicatif et Réplication)
# ==========================================
# Valeurs transmises en variables psql ; format(%I, %L) échappe identifiants et littéraux ;
# \gexec exécute le texte produit. Idempotent : création seulement si le rôle est absent,
# puis ALTER pour resynchroniser le mot de passe avec le .env.
echo "=> Configuration des rôles PostgreSQL..."
sudo -u postgres psql -p "${PORT_DB}" -v ON_ERROR_STOP=1 \
  -v app_user="${PGUSER}" -v app_pw="${PG_PASSWORD}" \
  -v repl_user="${PG_REPLICATION_USER}" -v repl_pw="${PG_REPLICATION_PASSWORD}" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'app_user')
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'app_user', :'app_pw') \gexec

SELECT format('CREATE ROLE %I REPLICATION LOGIN', :'repl_user')
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'repl_user') \gexec
SELECT format('ALTER ROLE %I REPLICATION LOGIN PASSWORD %L', :'repl_user', :'repl_pw') \gexec
SQL

echo "=> Rôle de supervision ${PG_EXPORTER_USER} (lecture seule : pg_monitor)..."
sudo -u postgres psql -p "${PORT_DB}" -v ON_ERROR_STOP=1 -q \
  -v ex_user="${PG_EXPORTER_USER}" -v ex_pw="${PG_EXPORTER_PASSWORD}" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'ex_user')
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'ex_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'ex_user', :'ex_pw') \gexec
SELECT format('GRANT pg_monitor TO %I', :'ex_user')
  WHERE NOT pg_has_role(:'ex_user', 'pg_monitor', 'member') \gexec
SQL

# ==========================================
# 6. Création de la base et application du schéma
# ==========================================
psql_postgres() { sudo -u postgres psql -p "${PORT_DB}" -v ON_ERROR_STOP=1 "$@"; }
psql_base()     { psql_postgres -d "${PGDATABASE}" "$@"; }

echo "=> Vérification et création de la base de données '${PGDATABASE}'..."
DB_EXISTS=$(psql_postgres -tA -v db="${PGDATABASE}" <<'SQL'
SELECT 1 FROM pg_database WHERE datname = :'db'
SQL
)
if [ "$DB_EXISTS" != "1" ]; then
  sudo -u postgres createdb -p "${PORT_DB}" -O "${PGUSER}" "${PGDATABASE}"
fi

table_existe() {
  psql_base -tAc "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = '${PGTABLE}');"
}

if [ "$(table_existe)" != "t" ]; then
  if [ -f "$FICHIER_SCHEMA" ]; then
    echo "==> Application du schéma (${FICHIER_SCHEMA})..."
    psql_base -1 -f "$FICHIER_SCHEMA"     # -1 : transaction unique, tout ou rien
  else
    echo "⚠️ AVERTISSEMENT : fichier de schéma introuvable (schema.sql / resultats.sql) : table non créée"
  fi
else
  echo "==> Table '${PGTABLE}' déjà présente : schéma non réappliqué."
fi

if [ "$PGUSER" != "postgres" ]; then
  echo "==> L'utilisateur applicatif devient propriétaire des tables et types du schéma public..."
  psql_base -q -v app_user="${PGUSER}" <<'SQL'
SELECT format('ALTER TABLE public.%I OWNER TO %I', tablename, :'app_user')
  FROM pg_tables WHERE schemaname = 'public' AND tableowner <> :'app_user' \gexec
SELECT format('ALTER TYPE public.%I OWNER TO %I', t.typname, :'app_user')
  FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public' AND t.typtype = 'e' AND pg_get_userbyid(t.typowner) <> :'app_user' \gexec
SQL
fi

echo "==> Attribution des droits sur le schéma public..."
psql_base -v app_user="${PGUSER}" <<'SQL'
SELECT format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO %I', :'app_user') \gexec
SELECT format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO %I', :'app_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO %I', :'app_user') \gexec
SQL

# ==========================================
# 7. Peuplement de la base de données (Data)
# ==========================================
if [ "$(table_existe)" = "t" ]; then
    NB_LIGNES=$(psql_base -tAc "SELECT count(*) FROM ${PGTABLE};")

    if [ "$NB_LIGNES" -eq 0 ]; then
      if [ -f "$FICHIER_DONNEES" ]; then
          echo "==> Peuplement de la base (${FICHIER_DONNEES})... Cela peut prendre un moment."
          psql_base -1 -f "$FICHIER_DONNEES"    # -1 : tout ou rien, sinon un chargement interrompu ne serait jamais repris
      else
          echo "⚠️ AVERTISSEMENT : fichier de données introuvable (data.sql) : table laissée vide"
      fi
    else
      echo "==> La base contient déjà ${NB_LIGNES} lignes. Peuplement ignoré (Idempotence respectée)."
    fi
else
    echo "⚠️ AVERTISSEMENT : La table '${PGTABLE}' n'existe pas. Impossible de vérifier les données."
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

echo "=> Exporter Prometheus PostgreSQL (port ${PORT_EXPORTER})..."
if paquet_present prometheus-postgres-exporter; then
  EXPORTER_MODIFIE=0
  if maj_fichier /etc/default/prometheus-postgres-exporter 0640 <<EOF
# Généré par bdd1.sh — ne pas éditer à la main
DATA_SOURCE_NAME="postgresql://${PG_EXPORTER_USER}:${PG_EXPORTER_PASSWORD}@127.0.0.1:${PORT_DB}/${PGDATABASE}?sslmode=disable"
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
    echo "   ⚠️  Exporter sans connexion à la base : sudo journalctl -u prometheus-postgres-exporter -n 20"
  fi
fi

echo "==================================================="
echo "✅ Serveur de Base de Données prêt !"
echo "Base : ${PGDATABASE} | Port : ${PORT_DB} | Accès autorisé depuis : ${APP_NETWORK}"
echo "Réplication autorisée pour l'utilisateur : ${PG_REPLICATION_USER}"
echo "==================================================="
