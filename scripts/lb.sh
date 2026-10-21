#!/bin/bash
# =====================================================================
#  lb.sh — Répartiteur de charge HAProxy (lb1)
#
#  - La liste des serveurs applicatifs est ENGENDRÉE depuis
#    config/noeuds.yml (source unique de vérité, exigence R3) :
#    aucune adresse n'est écrite en dur ici.
#  - Sonde de santé sur /sante toutes les secondes : un serveur est
#    écarté après 2 échecs, donc en 2 à 3 s (exigence R4 : < 5 s).
#  - Idempotent (R2) : rejoué deux fois, il ne modifie rien et ne
#    redémarre HAProxy que si la configuration a réellement changé.
# =====================================================================
set -euo pipefail

FICHIER_NOEUDS="${FICHIER_NOEUDS:-/vagrant/config/noeuds.yml}"
FICHIER_ENV_APP="${FICHIER_ENV_APP:-/vagrant/app/api/.env}"
CONF_HAPROXY="${CONF_HAPROXY:-/etc/haproxy/haproxy.cfg}"
PORT_LB=80          # port d'écoute du répartiteur (redirigé vers l'hôte par le Vagrantfile)
PORT_STATS=8404     # page de statistiques, joignable seulement sur le réseau privé

echo "==================================================="
echo " Déploiement du répartiteur de charge (HAProxy)    "
echo "==================================================="

# ---------------------------------------------------------------
# 1. Port des serveurs applicatifs : le même que celui utilisé par app.sh
# ---------------------------------------------------------------
PORT_APP=80
if [ -f "$FICHIER_ENV_APP" ]; then
  VAL=$(tr -d '\r' < "$FICHIER_ENV_APP" | awk -F= '$1=="PORT"{print $2}' | tail -n1)
  PORT_APP="${VAL:-80}"
fi

# ---------------------------------------------------------------
# 2. Lecture des serveurs applicatifs dans noeuds.yml
#    Format écrit par le Vagrantfile (to_yaml) :
#      - :nom: app1
#        :ip: 192.168.X.21
#        :role: app
# ---------------------------------------------------------------
if [ ! -f "$FICHIER_NOEUDS" ]; then
  echo "❌ Fichier introuvable : $FICHIER_NOEUDS" >&2
  exit 1
fi

# Produit une ligne "nom ip" par nœud dont le rôle est "app"
SERVEURS=$(tr -d '\r' < "$FICHIER_NOEUDS" | awk '
  function emettre() { if (role == "app" && nom != "" && ip != "") print nom, ip }
  /^- / { emettre(); nom = ""; ip = ""; role = "" }
  { sub(/^- /, "  ") }
  $1 == ":nom:"  { nom  = $2 }
  $1 == ":ip:"   { ip   = $2 }
  $1 == ":role:" { role = $2 }
  END { emettre() }
')

if [ -z "$SERVEURS" ]; then
  echo "❌ Aucun serveur applicatif (role: app) trouvé dans $FICHIER_NOEUDS" >&2
  exit 1
fi
echo "Serveurs applicatifs lus dans noeuds.yml (port ${PORT_APP}) :"
echo "$SERVEURS" | sed 's/^/   - /'

# ---------------------------------------------------------------
# 3. Installation (une seule fois)
# ---------------------------------------------------------------
if ! command -v haproxy >/dev/null 2>&1; then
  echo "=> Installation de HAProxy et UFW..."
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy ufw
else
  echo "=> HAProxy déjà installé : $(haproxy -v | head -n1)"
fi

# ---------------------------------------------------------------
# 4. Pare-feu
# ---------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow ssh > /dev/null
  sudo ufw allow "${PORT_LB}/tcp" > /dev/null
  sudo ufw allow "${PORT_STATS}/tcp" > /dev/null
  sudo ufw --force enable > /dev/null
fi

# ---------------------------------------------------------------
# 5. Génération de la configuration dans un fichier temporaire
# ---------------------------------------------------------------
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

{
cat <<EOF
# ==============================================================
#  FICHIER ENGENDRÉ PAR scripts/lb.sh — NE PAS MODIFIER À LA MAIN
#  Source : ${FICHIER_NOEUDS}
# ==============================================================
global
    log /dev/log local0
    maxconn 4096
    user haproxy
    group haproxy
    daemon

defaults
    mode http
    log global
    option httplog
    option dontlognull
    timeout connect 2s
    timeout client  30s
    timeout server  30s
    # Si un serveur tombe pendant une requête, on la rejoue sur un autre
    retries 2
    option redispatch
    retry-on conn-failure empty-response

frontend resultats_bf
    bind *:${PORT_LB}
    default_backend serveurs_app

backend serveurs_app
    balance roundrobin
    # Sonde de santé : seul un code 200 sur /sante maintient le serveur actif
    option httpchk GET /sante
    http-check expect status 200
    # inter 1s + fall 2 : serveur écarté en 2 à 3 secondes (R4 : < 5 s)
    default-server inter 1s fall 2 rise 2
EOF

while read -r NOM IP; do
  echo "    server ${NOM} ${IP}:${PORT_APP} check"
done <<< "$SERVEURS"

cat <<EOF

# Tableau de bord HAProxy : http://<IP de lb1>:${PORT_STATS}/stats
listen statistiques
    bind *:${PORT_STATS}
    stats enable
    stats uri /stats
    stats refresh 2s
    # Métriques Prometheus (exporter natif de HAProxy) : collectées par la VM obs
    http-request use-service prometheus-exporter if { path /metrics }
EOF
} > "$TMP"

# ---------------------------------------------------------------
# 6. Installation de la configuration seulement si elle a changé (R2)
# ---------------------------------------------------------------
if sudo cmp -s "$TMP" "$CONF_HAPROXY"; then
  echo "=> Configuration inchangée : HAProxy n'est pas redémarré."
else
  echo "=> Validation de la nouvelle configuration..."
  sudo haproxy -c -f "$TMP"
  sudo install -m 644 "$TMP" "$CONF_HAPROXY"
  sudo systemctl enable haproxy > /dev/null 2>&1 || true
  if sudo systemctl is-active --quiet haproxy; then
    sudo systemctl reload haproxy
    echo "=> Configuration appliquée (HAProxy rechargé, sans coupure)."
  else
    sudo systemctl restart haproxy
    echo "=> HAProxy démarré."
  fi
fi

# ---------------------------------------------------------------
# 7. Vérification (non bloquante)
# ---------------------------------------------------------------
echo "=> Test de /info à travers le répartiteur..."
for i in 1 2 3 4; do
  REP=$(curl -s --max-time 3 "http://127.0.0.1:${PORT_LB}/info" || true)
  echo "   appel ${i} : ${REP:-pas de réponse (les serveurs applicatifs sont-ils démarrés ?)}"
done

echo "==================================================="
echo "✅ Répartiteur prêt"
echo "   Service      : http://localhost:8080 depuis l'hôte"
echo "   Statistiques : http://<IP de lb1>:${PORT_STATS}/stats"
echo "==================================================="