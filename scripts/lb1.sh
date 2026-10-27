#!/bin/bash
# =============================================================================
#  lb1.sh — Provisionnement du répartiteur de charge ACTIF / PRIMAIRE (VM lb1)
#  HAProxy (équilibrage round-robin + sonde de santé) + Keepalived (VRRP, adresse virtuelle).
#
#  - Les serveurs applicatifs sont ENGENDRÉS depuis config/noeuds.yml (source unique de vérité,
#    exigence R3) : aucune adresse n'est écrite en dur. Ajouter un serveur = « vagrant up » puis
#    « vagrant provision lb1 lb2 » (ou scale), HAProxy se recharge SANS coupure.
#  - Sonde /sante toutes les secondes, serveur écarté après 2 échecs : 2 à 3 s (R4 : < 5 s).
#  - Socket d'administration HAProxy (/run/haproxy/admin.sock) : sert au « drain » du
#    déploiement sans coupure (continuous_deploiement).
#  - Métriques Prometheus sur http://<IP>:8404/metrics (collectées par la VM obs).
#  - VRRP : lb1 est MASTER (priorité 150) ; pair : lb2. L'adresse virtuelle (VIP) vient de
#    config/vip.env (« VIP=... »), à défaut <réseau>.5. Si HAProxy meurt sur ce nœud, sa priorité
#    chute de 60 et le pair reprend la VIP.
#  - VRRP_AUTH_PASS absent du .env => dérivé de PG_PASSWORD (même valeur sur lb1 et lb2).
#
#  IDEMPOTENT : configurations HAProxy et Keepalived engendrées dans un fichier temporaire, VALIDÉES,
#  puis installées SEULEMENT si elles diffèrent ; rechargement à chaud (jamais de coupure) ; services
#  démarrés/activés s'ils étaient arrêtés. Rejoué à l'identique : rien n'est modifié.
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

MON_NOM="lb1"; PEER_NOM="lb2"; STATE="MASTER"; PRIORITY=150
[ "$(hostname)" = "$MON_NOM" ] || { echo "❌ Ce script est réservé à la VM $MON_NOM (ici : $(hostname))." >&2; exit 1; }

CONF_HAPROXY="${CONF_HAPROXY:-/etc/haproxy/haproxy.cfg}"
CONF_KEEPALIVED="${CONF_KEEPALIVED:-/etc/keepalived/keepalived.conf}"
FICHIER_VIP="${FICHIER_VIP:-/vagrant/config/vip.env}"
PORT_LB=80          # port d'écoute du répartiteur
PORT_STATS=8404     # statistiques + métriques Prometheus, joignables sur le réseau privé

echo "==================================================="
echo " Déploiement du répartiteur de charge (HAProxy + Keepalived) sur ${MON_NOM}"
echo "==================================================="

# ---------------------------------------------------------------
# 1. Port des serveurs applicatifs : le même que celui utilisé par app.sh (PORT du .env)
# ---------------------------------------------------------------
PORT_APP=$(printf '%s' "${PORT:-80}" | tr -d '\r ')
case "$PORT_APP" in ''|*[!0-9]*) PORT_APP=80 ;; esac

# ---------------------------------------------------------------
# 2. Lecture des serveurs applicatifs dans noeuds.yml
#    Format écrit par le Vagrantfile (to_yaml) :  - :nom: app1 / :ip: 192.168.X.21 / :role: app
# ---------------------------------------------------------------
[ -f "$FICHIER_NOEUDS" ] || { echo "❌ Fichier introuvable : $FICHIER_NOEUDS" >&2; exit 1; }

SERVEURS=$(tr -d '\r"' < "$FICHIER_NOEUDS" | awk '
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
# 3. Installation (paquets manquants seulement)
#    socat : client du socket d'administration HAProxy (drain avant mise à jour)
# ---------------------------------------------------------------
apt_installer haproxy keepalived ufw socat curl

# ---------------------------------------------------------------
# 4. Adresses : pair VRRP, VIP, interface portant l'IP privée
# ---------------------------------------------------------------
MY_IP=$(noeud_ip "$MON_NOM")
PEER_IP=$(noeud_ip "$PEER_NOM")
if [ -z "$MY_IP" ] || [ -z "$PEER_IP" ]; then
  echo "❌ Impossible de trouver les IP de ${MON_NOM} ou ${PEER_NOM} dans $FICHIER_NOEUDS" >&2
  exit 1
fi
VIP=""
if [ -r "$FICHIER_VIP" ]; then VIP=$(tr -d '\r' < "$FICHIER_VIP" | awk -F= '$1=="VIP" {print $2}' | tail -n1 | tr -d ' "'"'"); fi
VIP="${VIP:-${MY_IP%.*}.5}"          # repli : .5, comme sur le schéma du sujet
secret_defaut VRRP_AUTH_PASS
AUTH_PASS="${VRRP_AUTH_PASS:0:8}"    # keepalived limite auth_pass à 8 caractères

INTERFACE=$(ip -o -4 addr show | awk -v ip="$MY_IP" '{split($4, a, "/"); if (a[1] == ip) {print $2; exit}}')
if [ -z "$INTERFACE" ]; then
  INTERFACE=eth1
  echo "⚠️  Interface de $MY_IP introuvable : repli sur $INTERFACE"
fi
echo "Hôte : $MON_NOM ($STATE) | IP : $MY_IP | pair : $PEER_NOM $PEER_IP | VIP : $VIP | interface : $INTERFACE"

# ---------------------------------------------------------------
# 5. Pare-feu ("ufw allow" est idempotent)
#    Le VRRP (protocole IP 112, unicast ici) doit passer entre les deux répartiteurs : sans cela,
#    chacun se déclare MASTER (split-brain).
# ---------------------------------------------------------------
ufw allow ssh > /dev/null
ufw allow "${PORT_LB}/tcp" > /dev/null
ufw allow "${PORT_STATS}/tcp" > /dev/null
ufw allow from "$PEER_IP" > /dev/null
ufw --force enable > /dev/null

# ---------------------------------------------------------------
# 6. HAProxy : configuration engendrée dans un fichier temporaire
# ---------------------------------------------------------------
TMP=$(mktemp); TMP_KA=$(mktemp)
trap 'rm -f "$TMP" "$TMP_KA"' EXIT

{
cat <<EOF
# ==============================================================
#  FICHIER ENGENDRÉ PAR scripts/${MON_NOM}.sh — NE PAS MODIFIER À LA MAIN
#  Source : ${FICHIER_NOEUDS}
# ==============================================================
global
    log /dev/log local0
    # Socket d'administration : permet le DRAIN d'un serveur pendant un déploiement
    stats socket /run/haproxy/admin.sock mode 660 level admin
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

# Tableau de bord : http://<IP de ${MON_NOM}>:${PORT_STATS}/stats
listen statistiques
    bind *:${PORT_STATS}
    stats enable
    stats uri /stats
    stats refresh 2s
    # Métriques Prometheus (exporter natif de HAProxy) : collectées par la VM obs
    http-request use-service prometheus-exporter if { path /metrics }
EOF
} > "$TMP"

HAP_CHANGE=0
if cmp -s "$TMP" "$CONF_HAPROXY" 2>/dev/null; then
  echo "=> Configuration HAProxy inchangée."
else
  echo "=> Validation de la nouvelle configuration HAProxy..."
  haproxy -c -f "$TMP" > /dev/null || { echo "❌ Configuration HAProxy invalide : $CONF_HAPROXY n'a PAS été modifié." >&2; haproxy -c -f "$TMP" >&2 || true; exit 1; }
  install -m 644 "$TMP" "$CONF_HAPROXY"
  HAP_CHANGE=1
fi
systemctl enable haproxy > /dev/null 2>&1 || true
if ! systemctl is-active --quiet haproxy; then
  systemctl restart haproxy
  echo "=> HAProxy démarré."
elif [ "$HAP_CHANGE" -eq 1 ]; then
  systemctl reload haproxy
  echo "=> Configuration appliquée (HAProxy rechargé, sans coupure)."
else
  echo "=> HAProxy déjà actif : rien à faire."
fi

# ---------------------------------------------------------------
# 7. Keepalived (VRRP) : configuration validée AVANT d'être installée
# ---------------------------------------------------------------
cat > "$TMP_KA" <<EOF
# Généré par ${MON_NOM}.sh — ne pas éditer à la main
global_defs {
    router_id $MON_NOM
    enable_script_security
    script_user root
}

# Retire 60 points de priorité tant que HAProxy n'est pas actif :
# 150-60 = 90 < 100, donc le pair reprend la VIP si HAProxy meurt ici.
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
chmod 600 "$TMP_KA"      # contient le secret VRRP

KA_CHANGE=0
if cmp -s "$TMP_KA" "$CONF_KEEPALIVED" 2>/dev/null; then
  echo "=> Configuration Keepalived inchangée."
else
  echo "=> Validation de la nouvelle configuration VRRP..."
  keepalived -t -f "$TMP_KA" > /dev/null 2>&1 || { echo "❌ Configuration keepalived invalide : $CONF_KEEPALIVED n'a PAS été modifié." >&2; keepalived -t -f "$TMP_KA" >&2 || true; exit 1; }
  install -m 600 "$TMP_KA" "$CONF_KEEPALIVED"
  KA_CHANGE=1
fi
systemctl enable keepalived > /dev/null 2>&1 || true
if ! systemctl is-active --quiet keepalived; then
  systemctl restart keepalived
  echo "=> Keepalived démarré."
elif [ "$KA_CHANGE" -eq 1 ]; then
  systemctl reload keepalived
  echo "=> Keepalived rechargé."
else
  echo "=> Keepalived déjà actif : rien à faire."
fi

# ---------------------------------------------------------------
# 8. Vérifications (non bloquantes)
# ---------------------------------------------------------------
echo "=> Test de /info à travers le répartiteur..."
for i in 1 2 3 4; do
  REP=$(curl -s --max-time 3 "http://127.0.0.1:${PORT_LB}/info" || true)
  echo "   appel ${i} : ${REP:-pas de réponse (les serveurs applicatifs sont-ils démarrés ?)}"
done
sleep 2
if ip -4 addr show | grep -q " ${VIP}/"; then
  echo "   ℹ️  ${MON_NOM} détient actuellement la VIP ${VIP}"
else
  echo "   ℹ️  ${MON_NOM} ne détient pas la VIP ${VIP}$([ "$STATE" = BACKUP ] && echo ' (normal sur le BACKUP)')"
fi

echo "==================================================="
echo "✅ Répartiteur ${MON_NOM} prêt (${STATE}, priorité ${PRIORITY})"
echo "   Depuis l'hôte : http://localhost:8080"
echo "   Adresse stable (VIP VRRP) : http://${VIP}"
echo "   Statistiques  : http://${MY_IP}:${PORT_STATS}/stats   | métriques : http://${MY_IP}:${PORT_STATS}/metrics"
echo "==================================================="
