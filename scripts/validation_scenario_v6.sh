#!/bin/bash
# V6 — Panne du répartiteur actif (extension E1) : vagrant halt lb1.
#      Le service doit rester joignable à la MÊME adresse (IP virtuelle VRRP), reprise < 5 s.
#      Usage : bash validation_scenario_v6.sh       (APRES=15 RESTAURER=1)
#  AUTONOME : la bibliothèque commune est intégrée ci-dessous (aucun autre fichier requis).
#  Rapport Markdown produit dans mesures/ (commande exacte, résultat brut, mesures, verdict, commentaire).
[ -n "${BASH_VERSION:-}" ] || { echo "À sourcer depuis bash" >&2; return 1 2>/dev/null || exit 1; }
set -uo pipefail

VAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RACINE="$VAL_DIR"                                      # racine du dépôt = dossier du Vagrantfile
while [ ! -f "$RACINE/Vagrantfile" ] && [ "$RACINE" != "/" ]; do RACINE="$(dirname "$RACINE")"; done
[ -f "$RACINE/Vagrantfile" ] || { echo "Vagrantfile introuvable au-dessus de $VAL_DIR" >&2; exit 1; }
cd "$RACINE" || exit 1

# ---------- Variables d'environnement : .env puis app/api/.env, sans écraser l'environnement ----------
charger_env() {
  [ -r "$1" ] || return 0
  local l k v
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"; case "$l" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    k="${l%%=*}"; v="${l#*=}"; k="${k// /}"
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [ -n "${!k+x}" ] || export "$k=$v"
  done < "$1"
}
charger_env .env; charger_env app/api/.env
export GROUPE="${GROUPE:-1}" NB_APP="${NB_APP:-2}"   # exportés : les commandes vagrant en ont besoin
PG_PORT="${PG_PORT:-5432}"; PG_DB="${PG_DB:-postgres}"
RESEAU="192.168.$((55 + GROUPE))"
LB_URL="${LB_URL:-http://127.0.0.1:8080}"

# ---------- Source de vérité : config/noeuds.yml ----------
noeuds() { [ -r config/noeuds.yml ] && tr -d '\r' < config/noeuds.yml | awk '$1=="-" && $2==":nom:" {nom=$3} $1==":ip:" {ip=$2} $1==":role:" {print nom, ip, $2}'; }
ip_de()  { noeuds | awk -v n="$1" '$1==n {print $2; exit}'; }
apps()   { noeuds | awk '$3=="app" {print $1}'; }
IP_LB1="$(ip_de lb1)"; IP_LB1="${IP_LB1:-$RESEAU.11}"
VIP="${IP_LB1%.*}.10"                       # même règle que keepalived.sh
VIP_URL="${VIP_URL:-http://$VIP}"

# ---------- Affichage + journal ----------
if [ -t 1 ]; then C_V=$'\033[32m'; C_R=$'\033[31m'; C_J=$'\033[33m'; C_B=$'\033[1m'; C_N=$'\033[0m'; else C_V=""; C_R=""; C_J=""; C_B=""; C_N=""; fi
RAP_JOURNAL="$(mktemp)"; RAP_MESURES="$(mktemp)"; RAP_VERDICTS="$(mktemp)"; RAP_OK=1; RAP_ID=""; RAP_TITRE=""; RAP_CMD=""
say()   { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$RAP_JOURNAL"; }
etape() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_N"; printf '\n== %s ==\n' "$*" >> "$RAP_JOURNAL"; }
ok()    { printf '  %s✅ %s%s\n' "$C_V" "$*" "$C_N"; printf '  [OK] %s\n' "$*" >> "$RAP_JOURNAL"; }
ko()    { printf '  %s❌ %s%s\n' "$C_R" "$*" "$C_N"; printf '  [ECHEC] %s\n' "$*" >> "$RAP_JOURNAL"; }
warn()  { printf '  %s⚠️  %s%s\n' "$C_J" "$*" "$C_N"; printf '  [ATTENTION] %s\n' "$*" >> "$RAP_JOURNAL"; }
cmd()   { printf '  $ %s\n' "$*"; printf '  $ %s\n' "$*" >> "$RAP_JOURNAL"; }
bloc()  { printf '%s\n' "$2" | sed 's/^/    /'; { printf '  -- %s --\n' "$1"; printf '%s\n' "$2" | sed 's/^/    /'; } >> "$RAP_JOURNAL"; }
mesure(){ printf '  • %-48s %s\n' "$1" "$2"; printf '| %s | %s |\n' "$1" "$2" >> "$RAP_MESURES"; }
verdict(){  # verdict ok|ko "texte"
  if [ "$1" = ok ]; then ok "$2"; printf -- '- ✅ %s\n' "$2" >> "$RAP_VERDICTS"
  else ko "$2"; printf -- '- ❌ %s\n' "$2" >> "$RAP_VERDICTS"; RAP_OK=0; fi
}
die() { printf '%s❌ %s%s\n' "$C_R" "$*" "$C_N" >&2; exit 1; }

rapport_debut() { RAP_ID="$1"; RAP_TITRE="$2"; RAP_CMD="$3"; printf '\n%s%s — %s%s\n' "$C_B" "$1" "$2" "$C_N"; }
rapport_fin() {
  mkdir -p mesures
  local f="mesures/${RAP_ID}_$(date +%Y%m%d_%H%M%S).md"
  {
    echo "# ${RAP_ID} — ${RAP_TITRE}"; echo
    echo "- Date : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- Poste : $(uname -sr) | vagrant $(vagrant --version 2>/dev/null | head -1)"
    echo "- Groupe ${GROUPE} (${RESEAU}.0/24) | NB_APP=${NB_APP} | Répartiteur ${LB_URL}"; echo
    echo "## Commande exacte"; echo; echo '```'; echo "${RAP_CMD}"; echo '```'; echo
    echo "## Résultat brut"; echo; echo '```'; cat "$RAP_JOURNAL"; echo '```'; echo
    echo "## Mesures"; echo; echo "| Mesure | Valeur |"; echo "|---|---|"; cat "$RAP_MESURES"; echo
    echo "## Verdict"; echo; cat "$RAP_VERDICTS"; echo
    echo "## Commentaire"; echo; echo "_À rédiger : interprétation honnête des chiffres, limites (les VM se partagent un seul processeur)._"
  } > "$f"
  printf '\n%sRapport : %s%s\n' "$C_B" "$f" "$C_N"
  rm -f "$RAP_JOURNAL" "$RAP_MESURES" "$RAP_VERDICTS"
  [ "$RAP_OK" -eq 1 ]
}

# ---------- Outils ----------
exiger() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "Outil manquant : $c"; done; }
now_ms() {
  local t; t=$(date +%s%3N 2>/dev/null)
  case "$t" in ''|*[!0-9]*) t=$(python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null || echo $(( $(date +%s) * 1000 ))) ;; esac
  echo "$t"
}
vm()      { vagrant ssh "$1" -c "$2" </dev/null 2>/dev/null | tr -d '\r'; }
etat_vm() { vagrant status "$1" --machine-readable 2>/dev/null | awk -F, '$3=="state" {print $4; exit}'; }
http_get() {   # http_get <url> [timeout_s] -> HCODE, HBODY
  local out; out=$(curl -s -m "${2:-3}" -w $'\n%{http_code}' "$1" 2>/dev/null) || true
  HCODE="${out##*$'\n'}"; HBODY="${out%$'\n'*}"
  [[ "$HCODE" =~ ^[0-9]{3}$ ]] || { HCODE=000; HBODY=""; }
}
serveur_de() {
  local h; h=$(grep -oE 'app[0-9]+' <<< "$1" | head -1)
  [ -n "$h" ] || h=$(printf '%s' "$1" | tr -d '\n\r"{} ' | cut -c1-40)
  echo "$h"
}
nb_distincts() {   # nb_distincts <url> <nb_appels> : nombre de serveurs distincts vus
  local i; for i in $(seq 1 "$2"); do http_get "$1" 2; serveur_de "$HBODY"; done | sort -u | grep -c .
}
attendre_serveurs() {   # attendre_serveurs <n> [timeout_s] : attend que n serveurs répondent via LB
  local n="$1" t="${2:-120}" i
  for i in $(seq 1 "$t"); do
    [ "$(nb_distincts "$LB_URL/info" $((n * 4)))" -ge "$n" ] && return 0; sleep 1
  done; return 1
}
matricule() {   # matricule valide : $MATRICULE ou premier de la base (colonne matricule_candidat, cf. cache.sh)
  if [ -z "${MATRICULE:-}" ]; then
    MATRICULE=$(vm bdd1 "sudo -u postgres psql -p $PG_PORT -d $PG_DB -tAc 'SELECT matricule_candidat FROM resultat ORDER BY 1 LIMIT 1'" | head -1 | tr -d ' ')
  fi
  printf '%s' "${MATRICULE:-}"
}

# ---------- Sondes en arrière-plan (observation continue d'une URL) ----------
SONDES_DIR=""; SONDES_PIDS=()
sondes_demarrer() {   # <url> <travailleurs> <pause_s> <timeout_s>
  local url="$1" n="${2:-1}" pause="${3:-0.1}" to="${4:-2}" i
  SONDES_DIR="$(mktemp -d)"
  for i in $(seq 1 "$n"); do
    (
      while [ ! -e "$SONDES_DIR/stop" ]; do
        t=$(now_ms); http_get "$url" "$to"; h=$(serveur_de "$HBODY")
        echo "$t $HCODE ${h:--}" >> "$SONDES_DIR/w$i.log"
        sleep "$pause"
      done
    ) &
    SONDES_PIDS+=($!)
  done
}
sondes_arreter() {
  [ -n "$SONDES_DIR" ] || return 0
  touch "$SONDES_DIR/stop"
  [ "${#SONDES_PIDS[@]}" -gt 0 ] && wait "${SONDES_PIDS[@]}" 2>/dev/null
  SONDES_PIDS=(); cat "$SONDES_DIR"/w*.log 2>/dev/null | sort -n > "$SONDES_DIR/all.log"
}
trap 'touch "${SONDES_DIR:-/nonexistent}/stop" 2>/dev/null; exit 130' INT TERM

# Analyse d'un journal de sondes (lignes "ms code serveur"), t0 = instant de la panne (ms).
# Renseigne : A_TOTAL A_OK A_ERR A_FIRST_S A_LAST_S A_GAP_S A_LATE A_OPEN A_CODES
#   A_FIRST_S/A_LAST_S : première/dernière erreur, en secondes après t0 ; A_GAP_S : plus longue période
#   SANS aucune réponse 2xx (indisponibilité totale du service) ; A_LATE : erreurs plus de 5 s après t0.
analyser() {   # analyser <fichier> <t0_ms>
  eval "$(awk -v t0="$2" '
    { t=$1; c=$2; n++ }
    c ~ /^2[0-9][0-9]$/ { ok++; if (inerr) { g=t-last_ok; if (last_ok && g>gap) gap=g; inerr=0 } last_ok=t; next }
    { err++; codes[c]++; if (!first) first=t; last=t; if (t-t0>5000) late++; inerr=1 }
    END {
      if (inerr && last_ok) { g=last-last_ok; if (g>gap) gap=g; open=1 }
      cs=""; for (c in codes) cs=cs sprintf("%s x%d  ", c, codes[c]);
      printf "A_TOTAL=%d\nA_OK=%d\nA_ERR=%d\n", n, ok, err;
      printf "A_FIRST_S=%s\nA_LAST_S=%s\n", (first ? sprintf("%.2f",(first-t0)/1000) : "-"), (last ? sprintf("%.2f",(last-t0)/1000) : "-");
      printf "A_GAP_S=%.2f\nA_LATE=%d\nA_OPEN=%d\nA_CODES=\"%s\"\n", gap/1000, late, open, cs }' "$1")"
}

# ===================== Scénario =====================
APRES="${APRES:-15}"; RESTAURER="${RESTAURER:-1}"
rapport_debut V6 "Panne du répartiteur actif (lb1) — bascule VRRP" "bash validation_scenario_v6.sh   (VIP_URL=${VIP_URL})"
exiger curl awk vagrant
etape "Pré-vérifications"
[ "$(etat_vm lb2)" = running ] || { cmd "vagrant up lb2"; vagrant up lb2 >/dev/null 2>&1; }
for l in lb1 lb2; do
  A=$(vm "$l" "systemctl is-active keepalived" | head -1)
  DET=$(vm "$l" "ip -4 addr show | grep -c ' ${VIP}/'" | head -1 | tr -d ' ')
  say "  $l : keepalived=${A:-?}  détient la VIP ${VIP} : $([ "${DET:-0}" -ge 1 ] && echo OUI || echo non)"
done
http_get "$VIP_URL/info" 3; [[ "$HCODE" =~ ^2 ]] && ok "VIP joignable : ${VIP_URL}/info = ${HCODE}" || die "VIP ${VIP_URL} injoignable avant la panne (keepalived/lb2 ?)"

etape "Panne"
sondes_demarrer "$VIP_URL/info" 1 0.1 1
sleep 5
T0=$(now_ms); cmd "vagrant halt lb1   (T0)"; vagrant halt lb1 >/dev/null 2>&1
say "  vagrant halt terminé après $(( ($(now_ms) - T0) / 1000 )) s ; observation ${APRES} s..."; sleep "$APRES"
sondes_arreter; analyser "$SONDES_DIR/all.log" "$T0"
bloc "Codes HTTP sur la VIP" "$(awk '{print $2}' "$SONDES_DIR/all.log" | sort | uniq -c)"
DET2=$(vm lb2 "ip -4 addr show | grep -c ' ${VIP}/'" | head -1 | tr -d ' ')

etape "Mesures"
mesure "Sondes émises (pas de 0,1 s, timeout 1 s)" "$A_TOTAL"
mesure "Sondes en erreur" "$A_ERR   [${A_CODES:-aucune}]"
mesure "Temps de reprise (plus longue période sans réponse 2xx)" "${A_GAP_S} s"
mesure "lb2 détient la VIP après la panne" "$([ "${DET2:-0}" -ge 1 ] && echo oui || echo non)"
if [ "$A_ERR" -eq 0 ]; then say "  Aucune coupure détectée à l'échelle de la sonde (≈ 1 s) : la bascule a été plus rapide."; fi
[ "$A_OPEN" -eq 0 ] && verdict ok "Le service répond de nouveau à la même adresse" || verdict ko "Le service n'a pas repris sur ${VIP_URL}"
awk -v g="$A_GAP_S" 'BEGIN{exit !(g<5)}' && verdict ok "Reprise en ${A_GAP_S} s (< 5 s)" || verdict ko "Reprise en ${A_GAP_S} s (≥ 5 s)"
[ "${DET2:-0}" -ge 1 ] && verdict ok "lb2 a pris la VIP" || verdict ko "lb2 ne détient pas la VIP"

if [ "$RESTAURER" = 1 ]; then
  etape "Remise en état"
  cmd "vagrant up lb1"; vagrant up lb1 >/dev/null 2>&1 && ok "lb1 redémarré (il reprendra la VIP : priorité 150 > 100)"
fi
rm -rf "$SONDES_DIR"; rapport_fin
