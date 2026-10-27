#!/bin/bash
# =============================================================================
#  keepalived.sh — Extension E1 : VRRP entre lb1 (MASTER) et lb2 (BACKUP)
#
#  Corrections par rapport à la version précédente :
#   - démarre/active le service même si la configuration n'a pas changé
#     (service arrêté, machine redémarrée) ;
#   - valide la configuration AVANT de l'installer (un fichier invalide ne remplace plus
#     une configuration qui fonctionne) ;
#   - pare-feu : "ufw allow from <pair>" (accepte le VRRP, protocole IP 112) au lieu de
#     "proto vrrp" que toutes les versions d'ufw ne connaissent pas ;
#   - sonde vrrp_script : si HAProxy meurt sur le MASTER, la VIP bascule sur l'autre
#     répartiteur (avant, seule la perte de keepalived ou de la VM faisait basculer) ;
#   - plus aucun mot de passe écrit dans le script (R7) : VRRP_AUTH_PASS vient du .env ;
#   - la VIP vient de config/vip.env, écrit par le Vagrantfile (même valeur que les
#     scripts de validation), plus de "dernier octet = .10" codé ici.
#  Idempotent (R2) : rejoué, il ne modifie ni ne redémarre rien.
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

echo "==================================================="
echo " Déploiement de Keepalived (VRRP) sur $(hostname)"
echo "==================================================="

FICHIER_NOEUDS="/vagrant/config/noeuds.yml"
FICHIER_VIP="/vagrant/config/vip.env"
FICHIER_ENV_APP="/vagrant/app/api/.env"
CONF=/etc/keepalived/keepalived.conf

if [ -f "$FICHIER_ENV_APP" ]; then
  set -a
  # shellcheck disable=SC1090
  source <(tr -d '\r' < "$FICHIER_ENV_APP")
  set +a
fi
: "${VRRP_AUTH_PASS:?VRRP_AUTH_PASS absent : définissez-le dans app/api/.env (généré par le Vagrantfile, voir .env.exemple)}"
AUTH_PASS="${VRRP_AUTH_PASS:0:8}"      # keepalived limite auth_pass à 8 caractères

[ -r "$FICHIER_NOEUDS" ] || { echo "❌ $FICHIER_NOEUDS introuvable" >&2; exit 1; }
noeud_ip() {
  tr -d '\r"' < "$FICHIER_NOEUDS" |
    awk -v n="$1" '$1=="-" && $2==":nom:" {cur=$3} $1==":ip:" && cur==n {print $2; exit}'
}
IP_LB1=$(noeud_ip lb1)
IP_LB2=$(noeud_ip lb2)
if [ -z "$IP_LB1" ] || [ -z "$IP_LB2" ]; then
  echo "❌ Impossible de trouver les IP de lb1 ou lb2 dans $FICHIER_NOEUDS" >&2
  exit 1
fi

VIP=""
if [ -r "$FICHIER_VIP" ]; then
  VIP=$(tr -d '\r' < "$FICHIER_VIP" | awk -F= '$1=="VIP" {print $2}' | tail -n1)
fi
VIP="${VIP:-${IP_LB1%.*}.5}"          # repli : .5, comme sur le schéma du sujet

MON_NOM=$(hostname)
case "$MON_NOM" in
  lb1) STATE="MASTER"; PRIORITY=150; MY_IP=$IP_LB1; PEER_IP=$IP_LB2 ;;
  lb2) STATE="BACKUP"; PRIORITY=100; MY_IP=$IP_LB2; PEER_IP=$IP_LB1 ;;
  *)   echo "❌ Ce script ne doit être exécuté que sur lb1 ou lb2." >&2; exit 1 ;;
esac
echo "=> Hôte : $MON_NOM ($STATE) | IP : $MY_IP | pair : $PEER_IP | VIP : $VIP"

# --- Installation (une seule fois) ---
if ! command -v keepalived >/dev/null 2>&1; then
  echo "=> Installation de Keepalived..."
  apt-get update -y -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq keepalived
fi

# --- Interface portant l'IP privée (enp0s8, eth1, ...) ---
INTERFACE=$(ip -o -4 addr show | awk -v ip="$MY_IP" '{split($4, a, "/"); if (a[1] == ip) {print $2; exit}}')
if [ -z "$INTERFACE" ]; then
  INTERFACE=eth1
  echo "⚠️  Interface de $MY_IP introuvable : repli sur $INTERFACE"
fi

# --- Pare-feu : le VRRP (IP 112, unicast ici) doit passer entre les deux répartiteurs ---
# Sans cela, chacun se déclare MASTER (split-brain). "ufw allow" est idempotent.
if command -v ufw >/dev/null 2>&1; then
  ufw allow from "$PEER_IP" >/dev/null
fi

# --- Configuration engendrée ---
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
global_defs {
    router_id $MON_NOM
    enable_script_security
    script_user root
}

# Retire de la priorité de ce nœud (-60) tant que HAProxy n'est pas actif :
# 150-60 = 90 < 100, donc lb2 reprend la VIP si HAProxy meurt sur lb1.
vrrp_script chk_haproxy {
    script "/usr/bin/systemctl is-active --quiet haproxy"
    interval 1
    fall 2
    rise 2
    weight -60
}

vrrp_instance VI_1 {
    state $STATE
    interface $INTERFACE
    virtual_router_id 51
    priority $PRIORITY
    advert_int 1

    unicast_src_ip $MY_IP
    unicast_peer {
        $PEER_IP
    }

    authentication {
        auth_type PASS
        auth_pass $AUTH_PASS
    }

    virtual_ipaddress {
        $VIP/24
    }

    track_script {
        chk_haproxy
    }
}
EOF

CHANGE=0
if cmp -s "$TMP" "$CONF" 2>/dev/null; then
  echo "=> Configuration Keepalived inchangée."
else
  echo "=> Validation de la nouvelle configuration VRRP..."
  if ! keepalived -t -f "$TMP"; then
    echo "❌ Configuration keepalived invalide : $CONF n'a PAS été modifié." >&2
    exit 1
  fi
  install -m 644 "$TMP" "$CONF"
  CHANGE=1
fi

systemctl enable keepalived >/dev/null 2>&1 || true
if ! systemctl is-active --quiet keepalived; then
  systemctl restart keepalived
  echo "=> Keepalived démarré."
elif [ "$CHANGE" -eq 1 ]; then
  systemctl reload keepalived
  echo "=> Keepalived rechargé."
else
  echo "=> Keepalived déjà actif : rien à faire."
fi

# --- Vérification (non bloquante) ---
sleep 2
if ip -4 addr show | grep -q " ${VIP}/"; then
  echo "   ℹ️  $MON_NOM détient actuellement la VIP $VIP"
else
  echo "   ℹ️  $MON_NOM ne détient pas la VIP $VIP (normal sur le BACKUP)"
fi
echo "✅ Keepalived ($STATE) opérationnel."
