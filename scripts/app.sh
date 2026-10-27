#!/bin/bash
# =============================================================================
#  app.sh — Provisionnement d'un serveur applicatif (VM app1..appN)
#  Installe les dépendances, COMPILE l'API (Bun) en un seul fichier JS (dist/index.js) et
#  l'exécute sous systemd (service « api-app », Node.js), reliée à PostgreSQL et, si la VM
#  « cache » existe, à Redis.
#
#  IDEMPOTENT : rejoué, il ne modifie rien. Dépendances et compilation ne sont relancées QUE si
#  les sources (src/, package.json, bun.lock, tsconfig...) ont changé ; le service n'est
#  redémarré QUE si le bundle, le .env ou la configuration systemd ont réellement changé.
#
#  - Compilation DANS la VM (Linux), à partir de /vagrant/app/api copié dans /opt/app-src :
#    le node_modules de l'hôte (Windows) n'est jamais utilisé.
#  - Commande de build : le script « build » de package.json s'il existe (il doit produire
#    dist/index.js), sinon « bun build <point d'entrée> --target node --outfile dist/index.js »
#    (point d'entrée : src/index.ts, src/main.ts, src/server.ts ou index.ts).
#  - Variables facultatives (.env) : BUILD_CMD (commande de build à la place), BUN_VERSION,
#    APP_RUNTIME=node|bun (exécution du bundle ; node par défaut).
#  - Repli : sans package.json mais avec un dist/index.js déjà compilé, ce bundle est déployé tel quel.
#
#  - Secrets (PG_PASSWORD, REDIS_PASSWORD) : lus dans le .env (jamais dans ce script).
#  - Base visée : bdd1 (noeuds.yml), ou l'IP mémorisée par une bascule dans
#    /etc/api-app.primaire (la bascule survit à « vagrant provision »).
#  - Redis : configuré dès que la VM « cache » figure dans noeuds.yml (sauf :actif: false).
#  - Le .env est lu comme du texte, jamais exécuté.
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
echo " Déploiement de l'API Node.js (serveur applicatif $(hostname))"
echo "==================================================="

# --- VARIABLES ---
DOSSIER_SOURCE="/vagrant/app/api"
DOSSIER_EXECUTION="/opt/app"
FICHIER_ENTREE="dist/index.js"          # bundle JS unique produit par la compilation
DOSSIER_BUILD="/opt/app-src"            # copie de travail Linux où l'on installe les dépendances et compile
FICHIER_HASH_BUILD="$DOSSIER_BUILD/.build-hash"
APP_RUNTIME="${APP_RUNTIME:-node}"      # node (défaut) ou bun
PORT_APP=$(echo "${PORT:-80}" | tr -d '\r')
SERVICE_NAME="api-app"
FICHIER_ENV_SERVICE="/etc/${SERVICE_NAME}.env"       # variables calculées (prioritaires sur .env)
FICHIER_PRIMAIRE="/etc/${SERVICE_NAME}.primaire"     # IP du primaire après bascule (écrit par bascule.sh)

# Base de données : primaire mémorisé par une bascule, sinon bdd1 (lue dans noeuds.yml)
DB_HOST=""
if [ -s "$FICHIER_PRIMAIRE" ]; then
  DB_HOST=$(tr -d '\r\n ' < "$FICHIER_PRIMAIRE")
  echo "Database Host (bascule mémorisée) : ${DB_HOST}"
else
  DB_HOST=$(champ_noeud bdd1 ip)
  echo "Database Host (noeuds.yml): ${DB_HOST}"
fi
if [ -z "${DB_HOST}" ]; then
  echo "❌ Impossible de trouver l'IP de bdd1 dans $FICHIER_NOEUDS" >&2
  exit 1
fi

# Cache Redis : actif dès que la VM « cache » est déclarée dans noeuds.yml (sauf :actif: false)
BLOC_REDIS=""
CACHE_HOST=$(champ_noeud cache ip || true)
CACHE_ACTIF=$(champ_noeud cache actif || true)
if [ -n "$CACHE_HOST" ] && [ "$CACHE_ACTIF" != "false" ]; then
  secret_defaut REDIS_PASSWORD
  REDIS_PORT=$(echo "${REDIS_PORT:-6379}" | tr -d '\r')
  CACHE_TTL=${CACHE_TTL:-300}
  BLOC_REDIS="REDIS_HOST=${CACHE_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=$(envq "$REDIS_PASSWORD")
CACHE_TTL=${CACHE_TTL}"
  if [ -n "${CACHE_PREFIX:-}" ]; then BLOC_REDIS="${BLOC_REDIS}
CACHE_PREFIX=${CACHE_PREFIX}"; fi
  echo "Cache Redis actif : ${CACHE_HOST}:${REDIS_PORT}"
else
  echo "Cache Redis inactif (VM cache absente de noeuds.yml) : l'API fonctionne sans cache"
fi

# Secret obligatoire (R7)
: "${PG_PASSWORD:?PG_PASSWORD absent : définissez-le dans app/api/.env (généré par le Vagrantfile, voir .env.exemple)}"
PG_USER=${PG_USER:-postgres}
PG_HOST=${PG_HOST:-$DB_HOST}
PG_PORT=${PG_PORT:-5432}
PG_DB=${PG_DB:-postgres}

# Un PG_HOST de type loopback ne peut jamais fonctionner : la base est sur une autre VM
case "$PG_HOST" in
  localhost|127.0.0.1|::1)
    echo "⚠️  PG_HOST=${PG_HOST} pointe sur la VM locale, remplacé par ${DB_HOST}"
    PG_HOST="$DB_HOST"
    ;;
esac
# Après une bascule, l'IP mémorisée l'emporte sur tout PG_HOST du .env
if [ -s "$FICHIER_PRIMAIRE" ]; then PG_HOST="$DB_HOST"; fi


A_REDEMARRER=0     # passe à 1 si le code, le .env ou la configuration du service ont changé

# Empreinte du code déployé (bundle + .env nettoyé) : sert à savoir s'il faut redémarrer
empreinte() {
  sudo sh -c "cat '$DOSSIER_EXECUTION/$FICHIER_ENTREE' '$DOSSIER_EXECUTION/.env' 2>/dev/null | sha256sum | cut -d' ' -f1"
}

# ==========================================
# 1. Mise à jour et Installation
# ==========================================
apt_installer curl ca-certificates rsync ufw
if ! command -v node >/dev/null 2>&1; then
  echo "=> Installation de Node.js 20 (dépôt NodeSource)..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
fi
echo "Node.js $(node -v)"

# Bun : sert à installer les dépendances et à compiler (version lue dans mise.toml si elle y est fixée)
installer_bun() {
  local voulu="" actuel=""
  if [ -f "$DOSSIER_SOURCE/mise.toml" ]; then
    voulu=$(tr -d '\r' < "$DOSSIER_SOURCE/mise.toml" | sed -n -E 's/^[[:space:]]*bun[[:space:]]*=[[:space:]]*"?([0-9]+\.[0-9]+\.[0-9]+)"?.*/\1/p' | head -n1)
  fi
  voulu="${BUN_VERSION:-$voulu}"
  command -v bun >/dev/null 2>&1 && actuel=$(bun --version 2>/dev/null || true)
  if [ -n "$actuel" ] && { [ -z "$voulu" ] || [ "$actuel" = "$voulu" ]; }; then
    echo "Bun $actuel déjà installé"; return 0
  fi
  apt_installer unzip curl ca-certificates
  echo "=> Installation de Bun ${voulu:-(dernière version)}..."
  if ! curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash -s ${voulu:+"bun-v$voulu"}; then
    echo "   installateur bun.sh indisponible : repli sur npm"
    npm install -g "bun${voulu:+@$voulu}"
  fi
  command -v bun >/dev/null 2>&1 || { echo "❌ Bun introuvable après installation" >&2; exit 1; }
  echo "Bun $(bun --version)"
}

# ==========================================
# 2. Configuration du Pare-feu
# ==========================================
echo "=> Configuration du pare-feu UFW..."
ufw allow ssh
ufw allow "${PORT_APP}/tcp"
ufw --force enable

# ==========================================
# 3. Dépendances + compilation (si les sources ont changé) puis déploiement du bundle
# ==========================================
SRC_BUNDLE="$DOSSIER_SOURCE/$(dirname "$FICHIER_ENTREE")"      # repli : bundle déjà compilé sur l'hôte

if [ -f "$DOSSIER_SOURCE/package.json" ]; then
  echo "=> Copie des sources vers $DOSSIER_BUILD (sans node_modules, dist, .git, .env)..."
  mkdir -p "$DOSSIER_BUILD"
  rsync -a --delete --exclude node_modules --exclude dist --exclude .git \
    --exclude '/.env' --exclude '/.build-hash' "$DOSSIER_SOURCE/" "$DOSSIER_BUILD/"

  # Empreinte des sources : tout sauf node_modules, dist et le fichier d'empreinte lui-même
  HASH_SOURCES=$( (cd "$DOSSIER_BUILD" && find . \( -path ./node_modules -o -path ./dist -o -path ./.build-hash \) -prune -o -type f -print0 \
                    | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1) )

  if [ -f "$DOSSIER_BUILD/$FICHIER_ENTREE" ] && [ "$(cat "$FICHIER_HASH_BUILD" 2>/dev/null || true)" = "$HASH_SOURCES" ]; then
    echo "=> Sources inchangées : installation des dépendances et compilation ignorées"
  else
    installer_bun
    echo "=> Installation des dépendances (bun install)..."
    ( cd "$DOSSIER_BUILD" && { bun install --frozen-lockfile || bun install; } ) \
      || { echo "❌ bun install a échoué" >&2; exit 1; }

    rm -rf "$DOSSIER_BUILD/dist"
    SCRIPT_BUILD=$(cd "$DOSSIER_BUILD" && node -p "String(((require('./package.json').scripts) || {}).build || '')" 2>/dev/null || true)
    if [ -n "${BUILD_CMD:-}" ]; then
      echo "=> Compilation : $BUILD_CMD"
      ( cd "$DOSSIER_BUILD" && bash -c "$BUILD_CMD" ) || { echo "❌ La compilation (BUILD_CMD) a échoué" >&2; exit 1; }
    elif [ -n "$SCRIPT_BUILD" ]; then
      echo "=> Compilation : bun run build  ($SCRIPT_BUILD)"
      ( cd "$DOSSIER_BUILD" && bun run build ) || { echo "❌ bun run build a échoué" >&2; exit 1; }
    else
      POINT_ENTREE=""
      for f in src/index.ts src/main.ts src/server.ts index.ts; do
        if [ -f "$DOSSIER_BUILD/$f" ]; then POINT_ENTREE="$f"; break; fi
      done
      [ -n "$POINT_ENTREE" ] || { echo "❌ Pas de script « build » dans package.json et aucun point d'entrée (src/index.ts...) : définissez BUILD_CMD dans le .env" >&2; exit 1; }
      echo "=> Compilation : bun build $POINT_ENTREE --target node --outfile $FICHIER_ENTREE"
      ( cd "$DOSSIER_BUILD" && bun build "$POINT_ENTREE" --target node --outfile "$FICHIER_ENTREE" ) \
        || { echo "❌ bun build a échoué" >&2; exit 1; }
    fi
    [ -f "$DOSSIER_BUILD/$FICHIER_ENTREE" ] || { echo "❌ La compilation n'a pas produit $FICHIER_ENTREE (dans $DOSSIER_BUILD)" >&2; exit 1; }
    echo "$HASH_SOURCES" > "$FICHIER_HASH_BUILD"
    echo "   ✅ Compilation terminée ($(wc -c < "$DOSSIER_BUILD/$FICHIER_ENTREE") octets)"
  fi
  SRC_BUNDLE="$DOSSIER_BUILD/$(dirname "$FICHIER_ENTREE")"
elif [ ! -f "$DOSSIER_SOURCE/$FICHIER_ENTREE" ]; then
  echo "❌ Ni $DOSSIER_SOURCE/package.json (sources à compiler) ni $DOSSIER_SOURCE/$FICHIER_ENTREE (bundle déjà compilé) : rien à déployer." >&2
  exit 1
fi

echo "=> Déploiement du bundle vers $DOSSIER_EXECUTION..."
mkdir -p "$DOSSIER_EXECUTION"
FP_AVANT=$(empreinte)
rsync -a --delete --exclude package.json "$SRC_BUNDLE/" "$DOSSIER_EXECUTION/$(dirname "$FICHIER_ENTREE")/"

# .env venant de Windows : on installe une copie sans CRLF, seulement si son contenu change
if [ -f "$DOSSIER_SOURCE/.env" ]; then
  tr -d '\r' < "$DOSSIER_SOURCE/.env" | maj_fichier "$DOSSIER_EXECUTION/.env" 0600 || true
else
  rm -f "$DOSSIER_EXECUTION/.env"
fi

if [ ! -f "$DOSSIER_EXECUTION/$FICHIER_ENTREE" ]; then
  echo "❌ Fichier introuvable : $DOSSIER_EXECUTION/$FICHIER_ENTREE" >&2
  exit 1
fi

# Le bundle est un module ES : on le déclare explicitement
DOSSIER_ENTREE="$(dirname "$DOSSIER_EXECUTION/$FICHIER_ENTREE")"
echo '{"type":"module"}' | maj_fichier "$DOSSIER_ENTREE/package.json" 0644 || true

[ "$(empreinte)" = "$FP_AVANT" ] || A_REDEMARRER=1

# ==========================================
# 4. Variables d'environnement du service
# ==========================================
# Le bundle lit DATABASE_URL (ou PGHOST/PGUSER/... de node-postgres) ; on fournit aussi les PG_*.
urlenc() { node -p 'encodeURIComponent(process.argv[1])' "$1"; }
DATABASE_URL="postgresql://$(urlenc "$PG_USER"):$(urlenc "$PG_PASSWORD")@${PG_HOST}:${PG_PORT}/$(urlenc "$PG_DB")"

echo "=> Écriture de ${FICHIER_ENV_SERVICE}..."
if maj_fichier "$FICHIER_ENV_SERVICE" 0600 <<EOF
HOST=0.0.0.0
PORT=$PORT_APP
NODE_ENV=production
DATABASE_URL=$DATABASE_URL
PGHOST=$PG_HOST
PGPORT=$PG_PORT
PGUSER=$PG_USER
PGPASSWORD=$(envq "$PG_PASSWORD")
PGDATABASE=$PG_DB
PG_HOST=$PG_HOST
PG_PORT=$PG_PORT
PG_USER=$PG_USER
PG_PASSWORD=$(envq "$PG_PASSWORD")
PG_DB=$PG_DB
$BLOC_REDIS
EOF
then A_REDEMARRER=1; fi

# ==========================================
# 5. Service Systemd avec chargement du .env
# ==========================================
echo "=> Création du service Systemd..."
case "$APP_RUNTIME" in
  node) EXEC_RUNTIME=$(command -v node) ;;
  bun)  installer_bun; EXEC_RUNTIME=$(command -v bun) ;;
  *)    echo "❌ APP_RUNTIME doit valoir node ou bun (reçu : $APP_RUNTIME)" >&2; exit 1 ;;
esac
UNITE_MODIFIEE=0
if maj_fichier /etc/systemd/system/${SERVICE_NAME}.service 0644 <<EOF
[Unit]
Description=API Node.js avec variables .env
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DOSSIER_EXECUTION

# 1. Variables du fichier .env (le "-" évite l'échec si le fichier est absent)
EnvironmentFile=-$DOSSIER_EXECUTION/.env
# 2. Variables calculées par le provisioning, listées EN DERNIER pour écraser le .env
EnvironmentFile=$FICHIER_ENV_SERVICE

# Lancement du bundle compilé
ExecStart=$EXEC_RUNTIME $FICHIER_ENTREE

# Redémarrage automatique
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
then UNITE_MODIFIEE=1; A_REDEMARRER=1; fi

# ==========================================
# 6. Activation et Démarrage
# ==========================================
echo "=> Lancement du service..."
if [ "$UNITE_MODIFIEE" -eq 1 ]; then sudo systemctl daemon-reload; fi
sudo systemctl enable ${SERVICE_NAME} > /dev/null 2>&1
if [ "$A_REDEMARRER" -eq 1 ] || ! sudo systemctl is-active --quiet ${SERVICE_NAME}; then
  sudo systemctl restart ${SERVICE_NAME}
  echo "   service redémarré"
else
  echo "   configuration et code inchangés : service non redémarré"
fi

# ==========================================
# 7. Vérifications (non bloquantes)
# ==========================================
echo "=> Test réseau vers la base ${PG_HOST}:${PG_PORT}..."
if timeout 5 bash -c "exec 3<>/dev/tcp/${PG_HOST}/${PG_PORT}" 2>/dev/null; then
  echo "   ✅ Port PostgreSQL joignable"
else
  echo "   ⚠️  Port PostgreSQL injoignable (bdd1 est-elle démarrée ? 'vagrant up bdd1' d'abord)"
fi

echo "=> Test de l'API (/sante)..."
CODE="000"
for _ in $(seq 1 15); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT_APP}/sante" || true)
  [ "$CODE" = "200" ] && break
  sleep 2
done
if [ "$CODE" = "200" ]; then
  echo "   ✅ API opérationnelle et connectée à la base"
else
  echo "   ⚠️  /sante a répondu HTTP ${CODE} — voir : sudo journalctl -u ${SERVICE_NAME} -n 50"
fi

echo "==================================================="
echo "✅ Terminé !"
echo "Vérifiez le statut : sudo systemctl status $SERVICE_NAME"
echo "Lisez les logs     : sudo journalctl -u $SERVICE_NAME -f"
echo "==================================================="