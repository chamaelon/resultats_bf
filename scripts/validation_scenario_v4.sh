#!/bin/bash
# V4 — Panne de la base primaire : vagrant halt bdd1.
#      Attendu : /sante renvoie proprement 503 (jamais page blanche / erreur de connexion brute) ;
#      on chronomètre la procédure de bascule sur bdd2 (promotion + repointage des applications).
#      ATTENTION : l'état final est « bdd2 primaire, bdd1 éteinte » ; pour revenir à l'état initial, rejouez V5.
#      Usage : bash validation_scenario_v4.sh        (BASCULE_CMD="..." pour utiliser votre propre procédure)
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
    MATRICULE=$(vm bdd1 "sudo -u postgres psql -p $PG_PORT -d $PG_DB -tAc 'SELECT matricule FROM resultats ORDER BY 1 LIMIT 1'" | head -1 | tr -d ' ')
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
rapport_debut V4 "Panne de la base primaire et bascule sur bdd2" "bash validation_scenario_v4.sh"
exiger curl awk vagrant
IP2=$(ip_de bdd2); [ -n "$IP2" ] || die "bdd2 absente de config/noeuds.yml"
PSQL="sudo -u postgres psql -p ${PG_PORT} -d ${PG_DB}"

etape "Pré-vérifications"
http_get "$LB_URL/sante" 3; [ "$HCODE" = 200 ] && ok "/sante = 200 avant la panne" || die "/sante = $HCODE avant la panne : plateforme non saine"
vm bdd1 "$PSQL -qAtc 'CREATE TABLE IF NOT EXISTS _validation_repl(ts timestamptz DEFAULT now()); INSERT INTO _validation_repl DEFAULT VALUES;'" >/dev/null
N1=$(vm bdd1 "$PSQL -tAc 'SELECT count(*) FROM _validation_repl'" | head -1 | tr -d ' '); sleep 3
N2=$(vm bdd2 "$PSQL -tAc 'SELECT count(*) FROM _validation_repl'" | head -1 | tr -d ' ')
mesure "R5 : lignes de contrôle bdd1 / bdd2" "${N1:-?} / ${N2:-?}"
[ -n "$N1" ] && [ "$N1" = "$N2" ] && verdict ok "R5 : l'écriture faite sur bdd1 est visible sur bdd2" || verdict ko "R5 : réplication défaillante (bdd1=${N1:-?}, bdd2=${N2:-?})"

etape "Panne de la base primaire"
sondes_demarrer "$LB_URL/sante" 1 0.1 2
sleep 5
T0=$(now_ms); cmd "vagrant halt bdd1   (T0)"; vagrant halt bdd1 >/dev/null 2>&1
say "  vagrant halt terminé après $(( ($(now_ms) - T0) / 1000 )) s"
sleep 8

etape "Procédure de bascule (chronométrée)"
TB0=$(now_ms)
if [ -n "${BASCULE_CMD:-}" ]; then
  cmd "$BASCULE_CMD"; bash -c "$BASCULE_CMD" 2>&1 | sed 's/^/    /'
else
  cmd "vagrant ssh bdd2 -c \"SELECT pg_promote()\"   # 1. promotion du réplica"
  PROMU=$(vm bdd2 "$PSQL -tAc 'SELECT pg_promote(true,60)'" | head -1 | tr -d ' ')
  say "    pg_promote -> ${PROMU:-?}"
  # 2. repointage des applications : même format que app.sh (/etc/api-app.env) + IP mémorisée dans
  #    /etc/api-app.primaire (R6 : la bascule survit à un « vagrant provision », app.sh la relit)
  REPOINTER="sudo sed -i -E 's#^(DATABASE_URL=postgresql://[^@]*@)[^:/]+#\1${IP2}#; s#^(PGHOST|PG_HOST)=.*#\1=${IP2}#' /etc/api-app.env && echo ${IP2} | sudo tee /etc/api-app.primaire >/dev/null && sudo systemctl restart api-app"
  for a in $(apps); do
    [ "$(etat_vm "$a")" = running ] || continue
    cmd "vagrant ssh ${a} -c \"<repointer api-app vers ${IP2}>\""; vm "$a" "$REPOINTER" >/dev/null
  done
fi
# 3. retour de /sante à 200 via le répartiteur
RETOUR=0
for _ in $(seq 1 90); do http_get "$LB_URL/sante" 2; [ "$HCODE" = 200 ] && { RETOUR=1; break; }; sleep 1; done
TB1=$(now_ms)
sleep 2; sondes_arreter; analyser "$SONDES_DIR/all.log" "$T0"
RESUME=$(awk '{print $2}' "$SONDES_DIR/all.log" | sort | uniq -c)
bloc "Codes HTTP de /sante pendant tout le scénario" "$RESUME"

etape "Vérifications après bascule"
REC=$(vm bdd2 "$PSQL -tAc 'SELECT pg_is_in_recovery()'" | head -1 | tr -d ' ')
M=$(matricule); http_get "$LB_URL/resultat?matricule=${M}" 4
mesure "bdd2 en mode réplica (pg_is_in_recovery)" "${REC:-?}   (attendu : f)"
mesure "/resultat via le répartiteur après bascule" "HTTP ${HCODE}"

etape "Mesures"
PREMIER503=$(awk -v t0="$T0" '$1>t0 && $2==503 {printf "%.1f", ($1-t0)/1000; exit}' "$SONDES_DIR/all.log")
BRUTES=$(awk '$2!=200 && $2!=503 {n++} END{print n+0}' "$SONDES_DIR/all.log")
mesure "Délai panne → premier 503 sur /sante" "${PREMIER503:-jamais} s"
mesure "Réponses ni 200 ni 503 (erreurs brutes)" "$BRUTES"
mesure "Durée de la procédure de bascule" "$(( (TB1 - TB0) / 1000 )) s"
mesure "Indisponibilité totale (aucun 200)" "${A_GAP_S} s"
[ -n "$PREMIER503" ] && verdict ok "/sante renvoie 503 ${PREMIER503} s après la panne" || verdict ko "/sante n'a jamais renvoyé 503"
[ "$BRUTES" -eq 0 ] && verdict ok "Aucune erreur brute : uniquement 200 ou 503" || verdict ko "${BRUTES} réponse(s) ni 200 ni 503 (page blanche / connexion refusée ?)"
[ "$RETOUR" -eq 1 ] && [ "$REC" = f ] && verdict ok "Bascule réussie : service rétabli sur bdd2" || verdict ko "Bascule incomplète (retour 200 : ${RETOUR}, bdd2 réplica : ${REC:-?})"
rm -rf "$SONDES_DIR"; rapport_fin
