#!/bin/bash
# V3 — Montée en charge : ab -n 2000 -c 50 avec N=2 puis N=4 serveurs applicatifs.
#      Usage : bash validation_scenario_v3.sh
#      Variables : N_LISTE="2 4"  REQUETES=2000  CONCURRENCE=50  REPETITIONS=3  ENDPOINT=/resultat?matricule=...
#      Utilise 'ab' (Apache Bench) s'il est installé, sinon un générateur intégré (curl + xargs).
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
N_LISTE="${N_LISTE:-2 4}"; REQUETES="${REQUETES:-2000}"; CONCURRENCE="${CONCURRENCE:-50}"; REPETITIONS="${REPETITIONS:-3}"
rapport_debut V3 "Montée en charge (N = ${N_LISTE})" "bash validation_scenario_v3.sh   (N_LISTE=\"${N_LISTE}\" REQUETES=${REQUETES} CONCURRENCE=${CONCURRENCE} REPETITIONS=${REPETITIONS})"
exiger curl awk vagrant
NB_INITIAL="$NB_APP"
MAX=$(printf '%s\n' $N_LISTE "$NB_INITIAL" | sort -n | tail -1)

if [ -z "${ENDPOINT:-}" ]; then
  M=$(matricule)
  if [ -n "$M" ]; then ENDPOINT="/resultat?matricule=${M}"; else warn "Matricule introuvable (base vide ? colonne différente ?) : repli sur /info. Fixez MATRICULE=..."; ENDPOINT="/info"; fi
fi
URL="${LB_URL}${ENDPOINT}"
if command -v ab >/dev/null 2>&1; then OUTIL="ab"; else OUTIL="generateur-curl"; warn "ab absent : générateur intégré (curl+xargs). Les chiffres ne sont PAS comparables à ceux d'ab ; installez apache2-utils pour le dossier."; fi
say "  URL testée : ${URL} | outil : ${OUTIL} | ${REQUETES} requêtes, concurrence ${CONCURRENCE}, ${REPETITIONS} répétition(s)"

mesurer() {   # mesurer <url> -> RPS FAILED MEAN P95
  if [ "$OUTIL" = ab ]; then
    local sortie; sortie=$(ab -n "$REQUETES" -c "$CONCURRENCE" -s 15 "$1" 2>&1)
    RPS=$(awk '/^Requests per second/ {print $4}' <<< "$sortie")
    FAILED=$(awk '/^Failed requests/ {f=$3} /^Non-2xx responses/ {n=$3} END{print f+n}' <<< "$sortie")
    MEAN=$(awk '/^Time per request/ && /\(mean\)/ && !/across/ {print $4}' <<< "$sortie")
    P95=$(awk '$1=="95%" {print $2}' <<< "$sortie")
  else
    local tmp t0 t1; tmp=$(mktemp); t0=$(now_ms)
    seq 1 "$REQUETES" | xargs -P "$CONCURRENCE" -I{} curl -s -o /dev/null -m 15 -w '%{http_code} %{time_total}\n' "$1" > "$tmp"
    t1=$(now_ms)
    RPS=$(awk -v ms=$((t1 - t0)) 'END{printf "%.2f", NR*1000/ms}' "$tmp")
    FAILED=$(awk '$1 !~ /^2/ {f++} END{print f+0}' "$tmp")
    MEAN=$(awk '{s+=$2} END{printf "%.2f", s/NR*1000}' "$tmp")
    P95=$(sort -k2 -n "$tmp" | awk '{a[NR]=$2} END{printf "%.0f", a[int(NR*0.95)]*1000}')
    rm -f "$tmp"
  fi
  RPS="${RPS:-0}"; FAILED="${FAILED:-?}"; MEAN="${MEAN:-?}"; P95="${P95:-?}"
}

declare -A MEDIANE
for N in $N_LISTE; do
  etape "N = ${N} serveurs applicatifs"
  # serveurs en trop arrêtés : la config du répartiteur ne liste que NB_APP serveurs, mais on libère aussi le processeur
  for k in $(seq $((N + 1)) "$MAX"); do cmd "NB_APP=${MAX} vagrant halt app${k}"; NB_APP="$MAX" vagrant halt "app$k" >/dev/null 2>&1; done
  cmd "NB_APP=${N} vagrant up";             NB_APP="$N" vagrant up >/dev/null 2>&1 || warn "vagrant up a renvoyé une erreur"
  cmd "NB_APP=${N} vagrant provision lb1";  NB_APP="$N" vagrant provision lb1 >/dev/null 2>&1 || warn "provision lb1 en erreur"
  [ "$(etat_vm lb2)" = running ] && { NB_APP="$N" vagrant provision lb2 >/dev/null 2>&1 || true; }
  attendre_serveurs "$N" 120 && ok "${N} serveur(s) répondent via le répartiteur" || { ko "Les ${N} serveurs ne répondent pas"; continue; }
  for _ in $(seq 1 100); do curl -s -o /dev/null -m 5 "$URL"; done      # échauffement
  VALS=""
  for r in $(seq 1 "$REPETITIONS"); do
    cmd "$([ "$OUTIL" = ab ] && echo "ab -n ${REQUETES} -c ${CONCURRENCE} \"${URL}\"" || echo "xargs -P ${CONCURRENCE} curl ... (${REQUETES} requêtes)")"
    mesurer "$URL"
    say "  répétition ${r} : ${RPS} req/s | échecs ${FAILED} | latence moyenne ${MEAN} ms | p95 ${P95} ms"
    mesure "N=${N} répétition ${r}" "${RPS} req/s ; échecs ${FAILED} ; moy ${MEAN} ms ; p95 ${P95} ms"
    VALS="${VALS}${RPS}"$'\n'
  done
  MEDIANE[$N]=$(printf '%s' "$VALS" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  mesure "N=${N} MÉDIANE" "${MEDIANE[$N]} req/s"
done

etape "Comparaison"
PREMIER=$(printf '%s\n' $N_LISTE | head -1); DERNIER=$(printf '%s\n' $N_LISTE | tail -1)
if [ "$PREMIER" != "$DERNIER" ] && [ -n "${MEDIANE[$PREMIER]:-}" ] && [ -n "${MEDIANE[$DERNIER]:-}" ]; then
  GAIN=$(awk -v a="${MEDIANE[$PREMIER]}" -v b="${MEDIANE[$DERNIER]}" 'BEGIN{printf "%.1f", (b/a-1)*100}')
  mesure "Variation du débit N=${PREMIER} → N=${DERNIER}" "${GAIN} %"
  if awk -v g="$GAIN" 'BEGIN{exit !(g>0)}'; then verdict ok "Le débit augmente avec le nombre de serveurs (+${GAIN} %)"
  else
    warn "Le débit n'augmente pas (${GAIN} %). Ce n'est pas un échec : les VM se partagent le processeur de l'hôte. Expliquez-le dans le dossier."
    echo "- ℹ️ Débit non croissant (${GAIN} %) : résultat honnête à commenter (CPU partagé), pas une anomalie du script." >> "$RAP_VERDICTS"
  fi
fi

etape "Retour à NB_APP=${NB_INITIAL}"
for k in $(seq $((NB_INITIAL + 1)) "$MAX"); do NB_APP="$MAX" vagrant halt "app$k" >/dev/null 2>&1; done
NB_APP="$NB_INITIAL" vagrant provision lb1 >/dev/null 2>&1 && ok "répartiteur reconfiguré pour ${NB_INITIAL} serveurs"
rapport_fin
