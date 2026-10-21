#!/bin/bash
set -euo pipefail

echo "==================================================="
echo " Déploiement de l'API Node.js avec support .env    "
echo "==================================================="

# --- Variables (.env synchronisé via /vagrant, jamais versionné — R7) ---
if [ -f /vagrant/app/api/.env ]; then
  set -a
  # shellcheck disable=SC1091
  source <(tr -d '\r' < /vagrant/app/api/.env)
  set +a
fi

# --- VARIABLES ---
FICHIER_NOEUDS="/vagrant/config/noeuds.yml"
DOSSIER_SOURCE="/vagrant/app/api"
DOSSIER_EXECUTION="/opt/app"
FICHIER_ENTREE="dist/index.js"          # bundle JS unique produit par la compilation
PORT_APP=$(echo "${PORT:-80}" | tr -d '\r')
SERVICE_NAME="api-app"
FICHIER_ENV_SERVICE="/etc/${SERVICE_NAME}.env"   # variables calculées (prioritaires sur .env)

# IP de bdd1 lue dans noeuds.yml (généré par le Vagrantfile)
DB_HOST=$(awk '/:name: bdd1/ {found=1} found && /:ip:/ {print $2; found=0}' "$FICHIER_NOEUDS" | tr -d '\r')
if [ -z "${DB_HOST}" ]; then
  echo "❌ Impossible de trouver l'IP de bdd1 dans $FICHIER_NOEUDS" >&2
  exit 1
fi
echo "Database Host (noeuds.yml): ${DB_HOST}"

PG_USER=${PG_USER:-postgres}
PG_PASSWORD=${PG_PASSWORD:-postgres}
# CORRECTION : l'ancien code affectait la chaîne littérale "DB_HOST" (il manquait le $)
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

# ==========================================
# 1. Mise à jour et Installation
# ==========================================
echo "=> Mise à jour des paquets..."
sudo apt-get update -y
echo "=> Installation de Node.js et des outils nécessaires..."
sudo apt-get install -y curl ca-certificates rsync ufw
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
echo "Node.js $(node -v)"

# ==========================================
# 2. Configuration du Pare-feu
# ==========================================
echo "=> Configuration du pare-feu UFW..."
sudo ufw allow ssh
sudo ufw allow "${PORT_APP}/tcp"
sudo ufw --force enable

# ==========================================
# 3. Synchronisation (Inclut les fichiers cachés comme .env)
# ==========================================
echo "=> Copie des fichiers (code source + .env)..."
sudo mkdir -p "$DOSSIER_EXECUTION"
# rsync -a copie automatiquement les fichiers cachés (.env) s'ils sont présents
sudo rsync -a --delete "$DOSSIER_SOURCE/" "$DOSSIER_EXECUTION/"

# Le .env venant de Windows peut contenir des fins de ligne CRLF : systemd les
# garderait dans les valeurs (ex. mot de passe "postgres\r"). On nettoie la copie.
if [ -f "$DOSSIER_EXECUTION/.env" ]; then
  sudo sed -i 's/\r$//' "$DOSSIER_EXECUTION/.env"
fi

if [ ! -f "$DOSSIER_EXECUTION/$FICHIER_ENTREE" ]; then
  echo "❌ Fichier introuvable : $DOSSIER_EXECUTION/$FICHIER_ENTREE (l'API a-t-elle été compilée ?)" >&2
  exit 1
fi

# Le bundle est un module ES (import/import.meta) : on le déclare explicitement
# pour ne pas dépendre de la détection automatique de Node.
DOSSIER_ENTREE="$(dirname "$DOSSIER_EXECUTION/$FICHIER_ENTREE")"
if [ ! -f "$DOSSIER_ENTREE/package.json" ]; then
  echo '{"type":"module"}' | sudo tee "$DOSSIER_ENTREE/package.json" > /dev/null
fi

# ==========================================
# 4. Variables d'environnement du service
# ==========================================
# CORRECTION PRINCIPALE : le bundle lit DATABASE_URL (ou, à défaut, PGHOST/PGUSER/...
# de node-postgres) et PAS PG_HOST/PG_USER. Sans cela, il se connectait à 127.0.0.1:5432.
# On fournit donc DATABASE_URL + les variables PG* standard + les anciennes PG_*.
urlenc() { node -p 'encodeURIComponent(process.argv[1])' "$1"; }
DATABASE_URL="postgresql://$(urlenc "$PG_USER"):$(urlenc "$PG_PASSWORD")@${PG_HOST}:${PG_PORT}/$(urlenc "$PG_DB")"

echo "=> Écriture de ${FICHIER_ENV_SERVICE}..."
sudo install -m 600 /dev/null "$FICHIER_ENV_SERVICE"
sudo tee "$FICHIER_ENV_SERVICE" > /dev/null <<EOF
HOST=0.0.0.0
PORT=$PORT_APP
NODE_ENV=production
DATABASE_URL=$DATABASE_URL
PGHOST=$PG_HOST
PGPORT=$PG_PORT
PGUSER=$PG_USER
PGPASSWORD=$PG_PASSWORD
PGDATABASE=$PG_DB
PG_HOST=$PG_HOST
PG_PORT=$PG_PORT
PG_USER=$PG_USER
PG_PASSWORD=$PG_PASSWORD
PG_DB=$PG_DB
EOF

# ==========================================
# 5. Service Systemd avec chargement du .env
# ==========================================
echo "=> Création du service Systemd..."
sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null <<EOF
[Unit]
Description=API Node.js avec variables .env
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DOSSIER_EXECUTION

# 1. Variables du fichier .env (le "-" évite l'échec si le fichier est absent)
EnvironmentFile=-$DOSSIER_EXECUTION/.env
# 2. Variables calculées par le provisioning. CORRECTION : systemd donne priorité aux
#    EnvironmentFile sur Environment=, et le dernier fichier lu l'emporte ; ce fichier
#    est donc listé EN DERNIER pour écraser le .env (PG_HOST vide, etc.).
EnvironmentFile=$FICHIER_ENV_SERVICE

# Lancement du bundle compilé
ExecStart=/usr/bin/node $FICHIER_ENTREE

# Redémarrage automatique
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ==========================================
# 6. Activation et Démarrage
# ==========================================
echo "=> Lancement du service..."
sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_NAME}
sudo systemctl restart ${SERVICE_NAME}

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