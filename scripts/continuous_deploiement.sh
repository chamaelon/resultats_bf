#!/bin/bash
# =============================================================================
#  continuous_deploiement.sh — Déploiement continu SANS COUPURE (rolling update)   [Linux / macOS / WSL / Git Bash]
#  À LANCER SUR L'HÔTE (n'importe où dans le dépôt) :   bash continuous_deploiement.sh [options]
#  (Windows natif : continuous_deploiement.ps1, mêmes options, même comportement)
# -----------------------------------------------------------------------------
#  Pour CHAQUE serveur applicatif qui doit changer, un par un :
#    1. vérifie que tous les autres sont UP dans HAProxy (jamais deux hors service) ;
#    2. le met en DRAIN dans HAProxy (plus de nouvelles connexions) et attend que
#       ses sessions en cours se terminent ;
#    3. sauvegarde la version en place (/opt/app.prev), installe la nouvelle
#       (dist/index.js) et redémarre le service api-app ;
#    4. attend que /sante réponde 200 (et que /resultat soit vivant) ;
#       sinon : RETOUR ARRIÈRE automatique sur ce serveur et arrêt du déploiement ;
#    5. le remet en service (READY) et attend que HAProxy le voie UP ;
#    6. passe au suivant.
#
#  IDEMPOTENCE — mêmes paramètres => même état final, sans effet de bord :
#    - La version = empreinte SHA-256 de dist/index.js. Un serveur déjà à cette version
#      est SAUTÉ (ni drain, ni redémarrage) ; si tous le sont : "rien à faire", code 0.
#    - /opt/app.prev garde la dernière version DIFFÉRENTE : rejouer un déploiement ne
#      détruit plus la possibilité de retour arrière.
#    - --rollback ne permute pas : un serveur déjà sur la version précédente est sauté,
#      rejouer --rollback converge. Pour ré-avancer : relancer le déploiement.
#    - --force réinstalle et redémarre même si la version est identique.
#
#  Les serveurs sont lus dans config/noeuds.yml (source unique de vérité) :
#  aucun serveur n'est écrit en dur. Fonctionne donc avec NB_APP=2, 4, ...
#  AUTONOME : la logique exécutée dans les VM est EMBARQUÉE dans ce fichier (fonction ecrire_remote) ;
#  continuous_deploiement.ps1 en embarque la même copie. Aucun autre fichier à livrer.
#
#  Répartiteurs : le drain / la remise en service sont appliqués sur TOUS les répartiteurs en ligne
#  (lb1 et lb2) : le trafic est servi par celui qui détient la VIP, qui peut changer (scénario V6).
#
#  Options :
#    --charge[=N]   génère de la charge (N travailleurs, défaut 20) pendant tout le
#                   déploiement et compte les requêtes en erreur (démo E4)
#    --no-build     ne recompile pas (utilise app/api/dist/index.js tel quel)
#    --build        force la compilation (échoue si aucun outil de build)
#    --only a,b     ne traite que les serveurs listés (ex : --only app2)
#    --rollback     revient à la version précédente, serveur par serveur
#    --status       affiche versions et état HAProxy de chaque serveur, sans rien changer
#    --dry-run      affiche le plan sans rien exécuter
#    --force        réinstalle même si le serveur est déjà à la bonne version
#    --allow-single autorise le déploiement avec un seul serveur en ligne (COUPURE !)
#    -h, --help     cette aide
#
#  Variables (environnement) :
#    LB_VMS='lb1 lb2'  LB_URL=http://127.0.0.1:8080  PROBE_PATH=/info  ACCEPT='^2'
#    CHARGE_DELAY=0.05  SANTE_TIMEOUT=60  DRAIN_TIMEOUT=20  UP_TIMEOUT=40
#    HAPROXY_SOCK=/run/haproxy/admin.sock  BUILD_CMD='bun run build'
#
#  Codes de sortie : 0 succès (ou rien à faire) | 1 erreur avant déploiement |
#  2 nouvelle version refusée (retour arrière effectué) | 3 serveur cassé |
#  4 requêtes en erreur pendant la charge.
# =============================================================================
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
RACINE="$SELF_DIR"                                    # racine du dépôt = dossier du Vagrantfile
while [ ! -f "$RACINE/Vagrantfile" ] && [ "$RACINE" != "/" ]; do RACINE="$(dirname "$RACINE")"; done
[ -f "$RACINE/Vagrantfile" ] || { echo "❌ Vagrantfile introuvable au-dessus de $SELF_DIR" >&2; exit 1; }
cd "$RACINE" || exit 1

LB_VMS="${LB_VMS:-${LB_VM:-lb1 lb2}}"                 # répartiteurs sur lesquels drainer (LB_VM : ancien nom)
LB_URL="${LB_URL:-http://127.0.0.1:8080}"
PROBE_PATH="${PROBE_PATH:-/info}"
ACCEPT="${ACCEPT:-^2}"
CHARGE_DELAY="${CHARGE_DELAY:-0.05}"
SANTE_TIMEOUT="${SANTE_TIMEOUT:-60}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-20}"
UP_TIMEOUT="${UP_TIMEOUT:-40}"
HAPROXY_SOCK="${HAPROXY_SOCK:-/run/haproxy/admin.sock}"
FICHIER_NOEUDS="config/noeuds.yml"
REMOTE_SCRIPT="config/.cd-remote.sh"          # copie synchronisée dans /vagrant/config (fins de ligne LF garanties)

ACTION="deploy"; BUILD="auto"; CHARGE=0; CHARGE_WORKERS=20; ONLY=""; DRY=0; SINGLE=0; FORCE=0

# ---------- Affichage ----------
if [ -t 1 ]; then V=$'\033[32m'; R=$'\033[31m'; J=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'; else V=""; R=""; J=""; B=""; N=""; fi
titre() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
info()  { printf '   %s\n' "$*"; }
ok()    { printf '   %s✅ %s%s\n' "$V" "$*" "$N"; }
warn()  { printf '   %s⚠️  %s%s\n' "$J" "$*" "$N" >&2; }
die()   { printf '%s❌ %s%s\n' "$R" "$*" "$N" >&2; exit "${2:-1}"; }
usage() { sed -n '3,/^# =====/p' "$SELF" | sed '$d; s/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --charge)      CHARGE=1 ;;
    --charge=*)    CHARGE=1; CHARGE_WORKERS="${1#*=}" ;;
    --no-build)    BUILD=0 ;;
    --build)       BUILD=1 ;;
    --only)        ONLY="${2:-}"; shift ;;
    --only=*)      ONLY="${1#*=}" ;;
    --rollback)    ACTION="rollback" ;;
    --status)      ACTION="status" ;;
    --dry-run)     DRY=1 ;;
    --force)       FORCE=1 ;;
    --allow-single) SINGLE=1 ;;
    -h|--help)     usage ;;
    *) die "Option inconnue : $1 (voir --help)" ;;
  esac
  shift
done
case "$CHARGE_WORKERS" in ''|*[!0-9]*) die "--charge attend un nombre" ;; esac

TMP="$(mktemp -d)"
CHARGE_PIDS=()
DRAINED=()          # serveurs HAProxy mis en drain et pas encore remis en service
HAP_OK=0

# ---------- Nettoyage garanti (Ctrl+C, erreur, fin normale) ----------
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "${#CHARGE_PIDS[@]}" -gt 0 ]; then touch "$TMP/stop"; wait "${CHARGE_PIDS[@]}" 2>/dev/null; fi
  if [ "$HAP_OK" -eq 1 ] && [ "${#DRAINED[@]}" -gt 0 ]; then
    for s in "${DRAINED[@]}"; do hap "set server $s state ready" >/dev/null 2>&1 && info "serveur $s remis en service"; done
  fi
  rm -f "$REMOTE_SCRIPT"; rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------- Script exécuté DANS les VM applicatives (en root), embarqué ----------
# Écrit dans config/.cd-remote.sh (dossier synchronisé : visible dans les VM sous /vagrant/config).
ecrire_remote() {
cat <<'REMOTE_SH_FIN'
#!/bin/bash
# =============================================================================
#  cd-remote.sh — étape de déploiement exécutée DANS une VM applicative (en root)
#  Appelé par cd.sh (Linux/macOS/WSL/Git Bash) et cd.ps1 (Windows) : la logique
#  de déploiement est ICI, une seule fois, pour que les deux versions ne divergent jamais.
#
#  Usage : bash cd-remote.sh <info|deploy|rollback> [délai_santé_s] [force 0|1]
#  Sortie : des lignes d'information, puis UNE ligne "RESULT=<code> ..." lue par l'hôte.
#
#  Idempotence (mêmes paramètres => même état final, sans effet de bord) :
#   - La "version" d'un déploiement est l'empreinte SHA-256 (12 premiers caractères) de
#     dist/index.js. deploy ne fait RIEN (RESULT=UNCHANGED) si la version en place est
#     déjà celle de la source : pas de redémarrage, et surtout pas d'écrasement de
#     /opt/app.prev, qui reste la dernière version DIFFÉRENTE (cible du retour arrière).
#   - rollback ne fait RIEN si le serveur est déjà sur la version précédente. Il ne
#     permute pas les deux versions : rejoué, il converge au lieu d'osciller A -> B -> A.
#     Pour ré-avancer, on relance simplement un déploiement.
#   - force=1 réinstalle et redémarre même si la version est identique (jamais de
#     sauvegarde dans ce cas : .prev n'est pas touché).
# =============================================================================
set -uo pipefail

ACTION="${1:-info}"; SANTE_TIMEOUT="${2:-60}"; FORCE="${3:-0}"
SRC=/vagrant/app/api; DST=/opt/app; PREV=/opt/app.prev; SVC=api-app
PORT=$(awk -F= '$1=="PORT" {print $2}' "/etc/${SVC}.env" 2>/dev/null | tr -d '\r' | tail -1); PORT="${PORT:-80}"

# Empreinte courte du bundle d'un répertoire ("aucune" s'il n'y en a pas)
hash_de() {
  if [ -f "$1/dist/index.js" ]; then sha256sum "$1/dist/index.js" | cut -c1-12; else echo "aucune"; fi
}

attendre_sante() {
  local code
  for _ in $(seq 1 "$SANTE_TIMEOUT"); do
    if systemctl is-active --quiet "$SVC"; then
      code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${PORT}/sante" || true)
      if [ "$code" = "200" ]; then
        code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${PORT}/resultat" || true)
        case "$code" in 2*|4*) return 0 ;; esac    # sans paramètre : 400 attendu = route vivante
      fi
    fi
    sleep 1
  done
  return 1
}

installer() {   # installer <répertoire source> : recopie le code, sans toucher à ce qui est inchangé
  rsync -a --delete --exclude node_modules --exclude .git --exclude '/.env' --exclude 'dist/package.json' "$1/" "$DST/"
  # .env : copie nettoyée des fins de ligne Windows (CRLF), lisible par root seul (cf. app.sh)
  if [ -f "$1/.env" ]; then
    tr -d '\r' < "$1/.env" > "$DST/.env.tmp" && chmod 600 "$DST/.env.tmp" && mv "$DST/.env.tmp" "$DST/.env"
  else
    rm -f "$DST/.env"
  fi
  echo '{"type":"module"}' > "$DST/dist/package.json"     # le bundle est un module ES (cf. app.sh)
}
sauvegarder() {   # copie atomique de la version en place vers $PREV
  rm -rf "$PREV.tmp"; mkdir -p "$PREV.tmp"; rsync -a "$DST/" "$PREV.tmp/"
  rm -rf "$PREV"; mv "$PREV.tmp" "$PREV"
}

[ -d "$DST" ] || { echo "ERREUR : $DST absent, l'application n'a jamais été provisionnée (vagrant provision $(hostname))"; echo "RESULT=ERREUR"; exit 1; }
AVANT=$(hash_de "$DST")

case "$ACTION" in
  info)
    echo "RESULT=INFO CURRENT=$AVANT PREV=$(hash_de "$PREV") SOURCE=$(hash_de "$SRC")"
    exit 0 ;;

  deploy)
    CIBLE=$(hash_de "$SRC")
    [ "$CIBLE" != "aucune" ] || { echo "ERREUR : $SRC/dist/index.js introuvable (dossier app/api non synchronisé ?)"; echo "RESULT=ERREUR"; exit 1; }
    if [ "$AVANT" = "$CIBLE" ] && [ "$FORCE" != "1" ] && systemctl is-active --quiet "$SVC"; then
      echo "Version $CIBLE déjà en place et service actif : rien à faire."
      echo "RESULT=UNCHANGED AVANT=$AVANT APRES=$AVANT"; exit 0
    fi
    SAUVE=0
    if [ "$AVANT" != "$CIBLE" ]; then sauvegarder; SAUVE=1; fi   # .prev = dernière version DIFFÉRENTE
    installer "$SRC"
    systemctl restart "$SVC"
    if attendre_sante; then echo "RESULT=OK AVANT=$AVANT APRES=$(hash_de "$DST")"; exit 0; fi
    echo "La nouvelle version ne devient pas saine : retour arrière"
    journalctl -u "$SVC" -n 15 --no-pager 2>/dev/null | sed 's/^/   journal : /'
    if [ "$SAUVE" -eq 1 ]; then
      installer "$PREV"; systemctl restart "$SVC"
      if attendre_sante; then echo "RESULT=ROLLED_BACK AVANT=$AVANT APRES=$(hash_de "$DST")"; exit 2; fi
    fi
    echo "RESULT=BROKEN AVANT=$AVANT"; exit 3 ;;

  rollback)
    P=$(hash_de "$PREV")
    [ "$P" != "aucune" ] || { echo "ERREUR : aucune version précédente ($PREV)"; echo "RESULT=ERREUR"; exit 1; }
    if [ "$AVANT" = "$P" ] && [ "$FORCE" != "1" ] && systemctl is-active --quiet "$SVC"; then
      echo "Déjà sur la version précédente ($P) : rien à faire."
      echo "RESULT=UNCHANGED AVANT=$AVANT APRES=$AVANT"; exit 0
    fi
    installer "$PREV"          # .prev reste inchangé : rejouer --rollback ne change plus rien
    systemctl restart "$SVC"
    if attendre_sante; then echo "RESULT=OK AVANT=$AVANT APRES=$(hash_de "$DST")"; exit 0; fi
    echo "RESULT=BROKEN AVANT=$AVANT"; exit 3 ;;

  *) echo "Action inconnue : $ACTION"; echo "RESULT=ERREUR"; exit 1 ;;
esac
REMOTE_SH_FIN
}

# ---------- Accès aux VM ----------
vm() {   # vm <machine> <commande> : exécute dans la VM, sortie sans CR
  vagrant ssh "$1" -c "$2" < /dev/null 2>>"$TMP/vagrant.err" | tr -d '\r'
}
etat_vm() { vagrant status "$1" --machine-readable 2>/dev/null | awk -F, '$3=="state" {print $4; exit}'; }
remote() {   # remote <machine> <action> : exécute cd-remote.sh dans la VM
  vm "$1" "sudo bash /vagrant/$REMOTE_SCRIPT $2 $SANTE_TIMEOUT $FORCE"
}
champ() { printf '%s\n' "$1" | sed -n "s/.*$2=\([^ ]*\).*/\1/p" | tail -1; }   # champ <sortie> <CLE>

# ---------- HAProxy (socket d'administration, sur CHAQUE répartiteur en ligne) ----------
HAP_VMS=()          # répartiteurs en ligne, avec socket d'administration et socat
hap_sur() { vm "$1" "echo '$2' | sudo socat stdio $HAPROXY_SOCK"; }            # hap_sur <vm> <commande>
hap() { local l; for l in "${HAP_VMS[@]}"; do hap_sur "$l" "$1"; done; }       # commande sur TOUS les répartiteurs
hap_champ() {   # hap_champ <vm> <backend/serveur> <colonne> : champ de « show stat »
  hap_sur "$1" "show stat" | awk -F, -v p="${2%%/*}" -v s="${2##*/}" -v c="$3" '$1==p && $2==s {print $c; exit}'
}
hap_sessions() {   # somme des sessions en cours sur tous les répartiteurs
  local l n tot=0
  for l in "${HAP_VMS[@]}"; do n=$(hap_champ "$l" "$1" 5); case "$n" in ''|*[!0-9]*) ;; *) tot=$((tot + n)) ;; esac; done
  echo "$tot"
}
hap_statut() {     # premier état non-UP rencontré ; sinon UP (un répartiteur qui ne connaît pas le serveur est ignoré)
  local l st res=""
  for l in "${HAP_VMS[@]}"; do
    st=$(hap_champ "$l" "$1" 18); [ -n "$st" ] || continue
    case "$st" in UP*) [ -n "$res" ] || res="$st" ;; *) echo "$st"; return 0 ;; esac
  done
  echo "$res"
}

attendre_drain() {   # attend 0 session en cours sur le serveur
  local srv="$1" i n=""
  for i in $(seq 1 "$DRAIN_TIMEOUT"); do
    n=$(hap_sessions "$srv"); [ "${n:-1}" = "0" ] && return 0; sleep 1
  done
  warn "$srv : ${n:-?} session(s) encore ouverte(s) après ${DRAIN_TIMEOUT}s (on continue)"
}
attendre_up() {      # attend que HAProxy voie le serveur UP
  local srv="$1" i st=""
  for i in $(seq 1 "$UP_TIMEOUT"); do
    st=$(hap_statut "$srv"); case "$st" in UP*) return 0 ;; esac; sleep 1
  done
  warn "$srv : état HAProxy '${st:-?}' après ${UP_TIMEOUT}s"; return 1
}

# ---------- Lecture de la source de vérité ----------
[ -r "$FICHIER_NOEUDS" ] || die "$FICHIER_NOEUDS introuvable : lancez d'abord 'vagrant up' (le Vagrantfile le génère)"
command -v vagrant >/dev/null 2>&1 || die "vagrant est introuvable dans le PATH"
NOEUDS=$(tr -d '\r' < "$FICHIER_NOEUDS" | awk '$1=="-" && $2==":nom:" {nom=$3} $1==":ip:" {ip=$2} $1==":role:" {print nom, ip, $2}')
APPS=()   # "nom ip"
while read -r nom ip role; do
  [ "$role" = "app" ] || continue
  if [ -n "$ONLY" ]; then case ",$ONLY," in *",$nom,"*) ;; *) continue ;; esac; fi
  APPS+=("$nom $ip")
done <<< "$NOEUDS"
[ "${#APPS[@]}" -gt 0 ] || die "Aucun serveur applicatif trouvé dans $FICHIER_NOEUDS${ONLY:+ pour --only $ONLY}"

titre "Plan : $ACTION"
EN_LIGNE=()
for a in "${APPS[@]}"; do
  set -- $a
  if [ "$DRY" -eq 1 ]; then info "$1 ($2)"; EN_LIGNE+=("$a"); continue; fi
  if [ "$(etat_vm "$1")" = "running" ]; then EN_LIGNE+=("$a"); info "$1 ($2) : en ligne"
  else warn "$1 ($2) : VM arrêtée, ignorée"; fi
done
[ "$DRY" -eq 1 ] && { info "répartiteurs : $LB_VMS | charge : $CHARGE ($CHARGE_WORKERS travailleurs) | build : $BUILD | force : $FORCE"; exit 0; }
[ "${#EN_LIGNE[@]}" -gt 0 ] || die "Aucun serveur applicatif en ligne (vagrant up)"

# Copie du script exécuté dans les VM, avec des fins de ligne LF (même si Git l'a converti en CRLF)
ecrire_remote | tr -d '\r' > "$REMOTE_SCRIPT"

# ---------- Capacités HAProxy ----------
for l in $LB_VMS; do
  [ "$(etat_vm "$l")" = "running" ] || { warn "$l : VM arrêtée, ignorée pour le drain"; continue; }
  [ "$(vm "$l" "sudo test -S $HAPROXY_SOCK && echo oui")" = "oui" ] || { warn "$l : pas de socket HAProxy ($HAPROXY_SOCK)"; continue; }
  vm "$l" "command -v socat >/dev/null || sudo apt-get install -y -qq socat >/dev/null 2>&1; command -v socat >/dev/null && echo oui" | grep -q oui || { warn "$l : socat indisponible"; continue; }
  HAP_VMS+=("$l")
done
[ "${#HAP_VMS[@]}" -gt 0 ] && HAP_OK=1
if [ "$HAP_OK" -eq 1 ]; then
  ok "Socket d'administration HAProxy disponible sur ${HAP_VMS[*]} : drain activé"
else
  warn "Aucun répartiteur avec socket HAProxy ($HAPROXY_SOCK sur $LB_VMS) : PAS de drain."
  warn "Rejouez 'vagrant provision lb1 lb2' : lb1.sh/lb2.sh à jour déclarent le socket dans la section 'global'."
  [ "$ACTION" = "status" ] || warn "Sans drain, les requêtes en vol sur le serveur redémarré peuvent être coupées."
fi

SERVERS_STATE=""
[ "$HAP_OK" -eq 1 ] && SERVERS_STATE=$(hap_sur "${HAP_VMS[0]}" "show servers state")
srv_haproxy() {   # srv_haproxy <nom> <ip> -> "backend/serveur"
  printf '%s\n' "$SERVERS_STATE" |
    awk -v ip="$2" -v n="$1" 'NF>=6 && $1 ~ /^[0-9]+$/ && ($5==ip || $4==n) {print $2 "/" $4; exit}'
}

# ---------- Versions en place (une interrogation par VM) ----------
cle() { printf '%s' "${1//[^A-Za-z0-9_]/_}"; }
SOURCE_VERSION="inconnue"
for a in "${EN_LIGNE[@]}"; do
  set -- $a
  sortie=$(remote "$1" info)
  [ "$(champ "$sortie" RESULT)" = "INFO" ] || die "$1 : impossible de lire la version en place ($(printf '%s' "$sortie" | tail -1))"
  printf -v "CUR_$(cle "$1")"  '%s' "$(champ "$sortie" CURRENT)"
  printf -v "PRV_$(cle "$1")"  '%s' "$(champ "$sortie" PREV)"
  SOURCE_VERSION=$(champ "$sortie" SOURCE)
done
cur_de() { local v; v="CUR_$(cle "$1")"; printf '%s' "${!v}"; }
prv_de() { local v; v="PRV_$(cle "$1")"; printf '%s' "${!v}"; }

# ---------- --status ----------
if [ "$ACTION" = "status" ]; then
  titre "État des serveurs applicatifs (version de la source : $SOURCE_VERSION)"
  printf '   %-8s %-16s %-14s %-14s %s\n' "SERVEUR" "IP" "EN PLACE" "PRÉCÉDENTE" "HAPROXY"
  for a in "${EN_LIGNE[@]}"; do
    set -- $a; s=""; st=""
    if [ "$HAP_OK" -eq 1 ]; then s=$(srv_haproxy "$1" "$2"); [ -n "$s" ] && st="$s : $(hap_statut "$s")"; fi
    printf '   %-8s %-16s %-14s %-14s %s\n' "$1" "$2" "$(cur_de "$1")" "$(prv_de "$1")" "${st:--}"
  done
  exit 0
fi

# ---------- Compilation ----------
if [ "$ACTION" = "deploy" ]; then
  titre "Compilation"
  if [ "$BUILD" != "0" ]; then
    if [ -n "${BUILD_CMD:-}" ]; then
      (cd app/api && bash -c "$BUILD_CMD") || die "La compilation a échoué (BUILD_CMD)"
    elif command -v bun >/dev/null 2>&1 && grep -q '"build"' app/api/package.json 2>/dev/null; then
      (cd app/api && bun run build) || die "La compilation a échoué (bun run build)"
    elif command -v npm >/dev/null 2>&1 && grep -q '"build"' app/api/package.json 2>/dev/null; then
      (cd app/api && npm run build) || die "La compilation a échoué (npm run build)"
    elif [ "$BUILD" = "1" ]; then
      die "--build demandé mais aucun outil de compilation (bun/npm + script 'build') trouvé"
    else
      warn "Aucun outil de compilation détecté : utilisation de dist/index.js existant"
    fi
  else
    info "compilation ignorée (--no-build)"
  fi
  [ -f app/api/dist/index.js ] || die "app/api/dist/index.js introuvable : compilez l'API d'abord"
  # Les VM relisent dist/index.js dans le dossier synchronisé : on interroge à nouveau la version de la SOURCE
  # (la compilation vient peut-être de la changer).
  set -- ${EN_LIGNE[0]}
  SOURCE_VERSION=$(champ "$(remote "$1" info)" SOURCE)
  [ -n "$SOURCE_VERSION" ] && [ "$SOURCE_VERSION" != "aucune" ] || die "dist/index.js n'est pas visible depuis les VM (dossier app/api non synchronisé ?)"
  ok "Version à déployer : ${SOURCE_VERSION} ($(wc -c < app/api/dist/index.js | tr -d ' ') octets)"
fi

# ---------- Décision : qui doit changer ? (idempotence) ----------
titre "Décision par serveur"
A_FAIRE=(); A_SAUTER=()
for a in "${EN_LIGNE[@]}"; do
  set -- $a; nom="$1"; cur=$(cur_de "$nom"); prv=$(prv_de "$nom")
  if [ "$ACTION" = "deploy" ]; then
    if [ "$cur" = "$SOURCE_VERSION" ] && [ "$FORCE" -ne 1 ]; then
      info "$nom : déjà à la version $cur -> sauté"; A_SAUTER+=("$nom|$cur|déjà à jour"); continue
    fi
    info "$nom : $cur -> $SOURCE_VERSION"
  else
    if [ "$prv" = "aucune" ]; then warn "$nom : aucune version précédente -> sauté"; A_SAUTER+=("$nom|$cur|pas de version précédente"); continue; fi
    if [ "$cur" = "$prv" ] && [ "$FORCE" -ne 1 ]; then
      info "$nom : déjà sur la version précédente ($cur) -> sauté"; A_SAUTER+=("$nom|$cur|déjà revenu"); continue
    fi
    info "$nom : $cur -> $prv"
  fi
  A_FAIRE+=("$a")
done

if [ "${#A_FAIRE[@]}" -eq 0 ]; then
  if [ "$ACTION" = "rollback" ] && [ "${#A_SAUTER[@]}" -gt 0 ] && printf '%s\n' "${A_SAUTER[@]}" | grep -q 'pas de version précédente'; then
    die "Retour arrière impossible : au moins un serveur n'a pas de version précédente (aucun déploiement antérieur)."
  fi
  ok "Rien à faire : aucun serveur n'a été touché (idempotent)."
  exit 0
fi

if [ "${#EN_LIGNE[@]}" -lt 2 ] && [ "$SINGLE" -ne 1 ]; then
  die "Un seul serveur en ligne : le retirer provoquerait une COUPURE. Démarrez-en un second (ou --allow-single)."
fi

# ---------- Générateur de charge ----------
charge_start() {
  titre "Charge pendant le déploiement : ${CHARGE_WORKERS} travailleurs sur ${LB_URL}${PROBE_PATH}"
  local code
  code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "${LB_URL}${PROBE_PATH}" || true)
  [[ "$code" =~ $ACCEPT ]] || die "Le répartiteur ne répond pas correctement sur ${LB_URL}${PROBE_PATH} (HTTP ${code:-000}) : 'vagrant up lb1' ?"
  local i
  for i in $(seq 1 "$CHARGE_WORKERS"); do
    (
      while [ ! -e "$TMP/stop" ]; do
        c=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "${LB_URL}${PROBE_PATH}" 2>/dev/null || true)
        c="${c:-000}"
        echo "$c" >> "$TMP/w$i.log"
        [[ "$c" =~ $ACCEPT ]] || echo "$(date +%T) HTTP $c" >> "$TMP/erreurs.log"
        sleep "$CHARGE_DELAY"
      done
    ) &
    CHARGE_PIDS+=($!)
  done
  sleep 2
  ok "charge en cours"
}
ERREURS=0
charge_stop() {
  [ "${#CHARGE_PIDS[@]}" -gt 0 ] || return 0
  touch "$TMP/stop"; wait "${CHARGE_PIDS[@]}" 2>/dev/null; CHARGE_PIDS=()
  local total
  total=$(cat "$TMP"/w*.log 2>/dev/null | wc -l | tr -d ' ')
  ERREURS=$( [ -f "$TMP/erreurs.log" ] && wc -l < "$TMP/erreurs.log" | tr -d ' ' || echo 0 )
  titre "Bilan de la charge"
  info "Requêtes émises : ${total}"
  info "Codes HTTP      : $(cat "$TMP"/w*.log 2>/dev/null | sort | uniq -c | awk '{printf "%s×%s  ", $1, $2}')"
  if [ "$ERREURS" -eq 0 ]; then ok "0 requête en erreur pendant tout le déploiement"
  else warn "${ERREURS} requête(s) en erreur (voir ci-dessous)"; head -n 10 "$TMP/erreurs.log" | sed 's/^/      /' >&2; fi
}

# ---------- Déploiement serveur par serveur ----------
[ "$CHARGE" -eq 1 ] && charge_start

RECAP=(); STATUT_GLOBAL=0; DEBUT=$SECONDS
for a in "${A_FAIRE[@]}"; do
  set -- $a; NOM="$1"; IP="$2"; T0=$SECONDS
  titre "$NOM ($IP)"
  SRV=""
  if [ "$HAP_OK" -eq 1 ]; then
    SRV=$(srv_haproxy "$NOM" "$IP")
    [ -n "$SRV" ] || { warn "$NOM introuvable dans HAProxy (configuration lb à vérifier) : pas de drain"; }
  fi

  if [ -n "$SRV" ]; then
    # 1. Aucun autre serveur ne doit être déjà hors service
    for b in "${EN_LIGNE[@]}"; do
      set -- $b; [ "$1" = "$NOM" ] && continue
      o=$(srv_haproxy "$1" "$2"); [ -n "$o" ] || continue
      case "$(hap_statut "$o")" in UP*) ;; *)
        die "$1 n'est pas UP dans HAProxy : on ne retire pas un second serveur (déploiement interrompu avant $NOM)" ;;
      esac
    done
    # 2. Drain
    info "drain de $SRV dans HAProxy..."
    hap "set server $SRV state drain" >/dev/null
    DRAINED+=("$SRV")
    attendre_drain "$SRV"
  fi

  # 3-4. Installation, redémarrage, contrôle de santé (dans la VM)
  info "installation ($ACTION) et redémarrage..."
  SORTIE=$(remote "$NOM" "$ACTION")
  printf '%s\n' "$SORTIE" | grep -v '^RESULT=' | sed 's/^/      /'
  RES=$(champ "$SORTIE" RESULT)
  AV=$(champ "$SORTIE" AVANT)
  AP=$(champ "$SORTIE" APRES)

  case "$RES" in
    OK)          ok "$NOM : ${AV:-?} → ${AP:-?}" ;;
    UNCHANGED)   ok "$NOM : déjà à jour (${AP:-?})" ;;
    ROLLED_BACK) warn "$NOM : nouvelle version refusée, ancienne version restaurée (${AP:-?})"; STATUT_GLOBAL=2 ;;
    BROKEN)      warn "$NOM : hors service même après retour arrière (laissé en drain)"; STATUT_GLOBAL=3 ;;
    *)           warn "$NOM : échec de l'étape de déploiement (${RES:-aucune réponse})"; STATUT_GLOBAL=1 ;;
  esac

  # 5. Remise en service (sauf serveur cassé)
  if [ -n "$SRV" ] && [ "$RES" != "BROKEN" ]; then
    hap "set server $SRV state ready" >/dev/null
    attendre_up "$SRV" && ok "$SRV : UP dans HAProxy"
    NEW=(); for d in "${DRAINED[@]}"; do [ "$d" = "$SRV" ] || NEW+=("$d"); done
    DRAINED=("${NEW[@]+"${NEW[@]}"}")
  fi
  RECAP+=("$(printf '%-8s %-14s → %-14s %-12s %ss' "$NOM" "${AV:-?}" "${AP:-?}" "${RES:-?}" "$((SECONDS - T0))")")

  if [ "$STATUT_GLOBAL" -ne 0 ]; then
    warn "Déploiement INTERROMPU : les serveurs suivants n'ont pas été touchés."
    break
  fi
done

# ---------- Bilan ----------
charge_stop
titre "Récapitulatif (durée totale : $((SECONDS - DEBUT)) s)"
printf '   %-8s %-14s   %-14s %-12s %s\n' "SERVEUR" "AVANT" "APRÈS" "RÉSULTAT" "DURÉE"
for l in "${RECAP[@]}"; do printf '   %s\n' "$l"; done
if [ "${#A_SAUTER[@]}" -gt 0 ]; then
  for s in "${A_SAUTER[@]}"; do IFS='|' read -r n v r <<< "$s"; printf '   %-8s %-14s   %-14s %-12s %s\n' "$n" "$v" "$v" "SAUTÉ" "($r)"; done
fi

if [ "$STATUT_GLOBAL" -ne 0 ]; then exit "$STATUT_GLOBAL"; fi
if [ "$ERREURS" -gt 0 ]; then exit 4; fi
ok "Déploiement terminé sans coupure."
