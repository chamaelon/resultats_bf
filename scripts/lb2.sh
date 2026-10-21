#!/bin/bash
# =====================================================================
#  lb2.sh — Répartiteur de charge HAProxy de secours (LB2)
#
#  La liste des serveurs applicatifs est lue depuis /vagrant/config/noeuds.yml.
#  Sonde de santé sur /sante toutes les secondes.
#  Le script est idempotent : HAProxy n'est rechargé que si la configuration change.
# =====================================================================
set -euo pipefail

FICHIER_NOEUDS="${FICHIER_NOEUDS:-/vagrant/config/noeuds.yml}"
FICHIER_ENV_APP="${FICHIER_ENV_APP:-/vagrant/app/api/.env}"
CONF_HAPROXY="${CONF_HAPROXY:-/etc/haproxy/haproxy.cfg}"
PORT_LB=80
PORT_STATS=8404

echo "==================================================="
echo " Déploiement du répartiteur de charge (HAProxy LB2)"
echo "==================================================="

PORT_APP=80
if [ -f "$FICHIER_ENV_APP" ]; then
  VAL=$(tr -d '\r' < "$FICHIER_ENV_APP" | awk -F= '$1=="PORT"{print $2}' | tail -n1)
  PORT_APP="${VAL:-80}"
fi

if [ ! -f "$FICHIER_NOEUDS" ]; then
  echo "Fichier introuvable : $FICHIER_NOEUDS" >&2
  exit 1
fi

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
  echo "Aucun serveur applicatif (role: app) trouvé dans $FICHIER_NOEUDS" >&2
  exit 1
fi
echo "Serveurs applicatifs lus dans noeuds.yml (port ${PORT_APP}) :"
echo "$SERVEURS" | sed 's/^/   - /'

if ! command -v haproxy >/dev/null 2>&1; then
  echo "=> Installation de HAProxy et UFW..."
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy ufw
else
  echo "=> HAProxy déjà installé : $(haproxy -v | head -n1)"
fi

if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow ssh > /dev/null
  sudo ufw allow "${PORT_LB}/tcp" > /dev/null
  sudo ufw allow "${PORT_STATS}/tcp" > /dev/null
  sudo ufw --force enable > /dev/null
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

{
cat <<EOF
# ==============================================================
# FICHIER ENGENDRÉ PAR scripts/lb2.sh — NE PAS MODIFIER À LA MAIN
# Source : ${FICHIER_NOEUDS}
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
    retries 2
    option redispatch
    retry-on conn-failure empty-response

frontend resultats_bf
    bind *:${PORT_LB}
    default_backend serveurs_app

backend serveurs_app
    balance roundrobin
    option httpchk GET /sante
    http-check expect status 200
    default-server inter 1s fall 2 rise 2
EOF

while read -r NOM IP; do
  echo "    server ${NOM} ${IP}:${PORT_APP} check"
done <<< "$SERVEURS"

cat <<EOF

# Tableau de bord HAProxy : http://<IP de lb2>:${PORT_STATS}/stats
listen statistiques
    bind *:${PORT_STATS}
    stats enable
    stats uri /stats
    stats refresh 2s
EOF
} > "$TMP"

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

echo "=> Test de /info à travers le répartiteur..."
for i in 1 2 3 4; do
  REP=$(curl -s --max-time 3 "http://127.0.0.1:${PORT_LB}/info" || true)
  echo "   appel ${i} : ${REP:-pas de réponse (les serveurs applicatifs sont-ils démarrés ?)}"
done

echo "==================================================="
echo " Répartiteur LB2 prêt"
echo " Accès normal : via l'IP virtuelle VRRP configurée dans Keepalived"
echo " Statistiques : http://<IP de lb2>:${PORT_STATS}/stats"
echo "==================================================="
