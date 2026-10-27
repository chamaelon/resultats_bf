#!/bin/bash
# =============================================================================
#  obs.sh — Provisionnement de la VM « obs » : supervision Prometheus + Grafana
# -----------------------------------------------------------------------------
#  - Prometheus collecte toutes les 5 s : node_exporter de CHAQUE VM, HAProxy (lb1/lb2,
#    port 8404), Redis (cache, port 9121) et PostgreSQL (bdd1/bdd2, port 9187).
#  - Les cibles sont ENGENDRÉES depuis /vagrant/config/noeuds.yml (même source de vérité que
#    le Vagrantfile) : NB_APP=4 vagrant up => nouvelles cibles sans rien toucher (un timer
#    systemd les régénère toutes les 30 s).
#  - Grafana est provisionné en code : datasource + tableau de bord « RÉSULTATS-BF — Supervision »
#    (disponibilité, débit, CPU, mémoire, HAProxy, Redis, PostgreSQL et réplication).
#  - Alertes Prometheus : VM injoignable, serveur applicatif hors ligne, Redis ou PostgreSQL
#    injoignable, retard de réplication.
#
#  IDEMPOTENT : rejoué, il ne modifie, ne recharge et ne redémarre que ce qui a changé
#  (Prometheus : redémarré seulement si ses arguments changent, sinon rechargé à chaud).
#
#  - GRAFANA_PASSWORD absent du .env => dérivé de PG_PASSWORD et affiché en fin de script.
#  - Accès depuis l'hôte, SANS redirection de port :
#        Grafana    http://<RESEAU>.41:3000
#        Prometheus http://<RESEAU>.41:9090
# =============================================================================
set -euo pipefail
APT_OPTS="--no-install-recommends"        # la VM n'a que 768 Mo

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
echo " Déploiement de la supervision (Prometheus + Grafana)"
echo "==================================================="

GRAFANA_PW_DERIVE=0
[ -n "${GRAFANA_PASSWORD:-}" ] || GRAFANA_PW_DERIVE=1
secret_defaut GRAFANA_PASSWORD
PROM_RETENTION="${PROM_RETENTION:-6h}"              # démo : 6 h suffisent
PROM_RETENTION_SIZE="${PROM_RETENTION_SIZE:-300MB}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-5s}"
PORT_PROM=9090
PORT_GRAFANA=3000
PORT_NODE=9100
PORT_HAPROXY="${PORT_HAPROXY:-8404}"
PORT_REDIS_EXPORTER=9121
PORT_PG_EXPORTER=9187

[ -r "$FICHIER_NOEUDS" ] || { echo "❌ $FICHIER_NOEUDS introuvable" >&2; exit 1; }

OBS_IP=$(noeud_ip obs)
if [ -z "$OBS_IP" ]; then
  echo "❌ Le nœud 'obs' est absent de $FICHIER_NOEUDS (voir le Vagrantfile)" >&2
  exit 1
fi
RESEAU_CIDR="${OBS_IP%.*}.0/24"
echo "obs : ${OBS_IP} | réseau privé : ${RESEAU_CIDR}"

# ==========================================
# 0. Mémoire : la VM n'a que 512-768 Mo
# ==========================================
MEM_MO=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$MEM_MO" -lt 900 ] && ! grep -q '^/swapfile' /proc/swaps; then
  echo "=> Mémoire limitée (${MEM_MO} Mo) : création d'un swap de 512 Mo..."
  [ -f /swapfile ] || { fallocate -l 512M /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null; }
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ==========================================
# 1. Installation (paquets groupés — connexion lente)
# ==========================================
apt_installer prometheus prometheus-node-exporter curl gnupg ca-certificates ufw python3
systemctl enable --now prometheus-node-exporter >/dev/null 2>&1 || true

GRAFANA_OK=1
if ! paquet_present grafana; then
  echo "=> Installation de Grafana (dépôt officiel apt.grafana.com)..."
  if (
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/grafana.gpg
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
      > /etc/apt/sources.list.d/grafana.list
    apt-get update -y
    apt-get install -y grafana
  ); then :; else
    GRAFANA_OK=0
    echo "⚠️  Installation de Grafana impossible (réseau ?). Prometheus reste fonctionnel ;" >&2
    echo "   relancez : vagrant provision obs" >&2
  fi
fi

# ==========================================
# 2. Pare-feu
# ==========================================
echo "=> Configuration du pare-feu UFW..."
ufw allow ssh >/dev/null
ufw allow from "$RESEAU_CIDR" to any port "$PORT_PROM" proto tcp >/dev/null
ufw allow from "$RESEAU_CIDR" to any port "$PORT_GRAFANA" proto tcp >/dev/null
ufw allow from "$RESEAU_CIDR" to any port "$PORT_NODE" proto tcp >/dev/null
ufw --force enable >/dev/null

# ==========================================
# 3. Cibles Prometheus engendrées depuis noeuds.yml
# ==========================================
echo "=> Génération des cibles depuis ${FICHIER_NOEUDS}..."
install -d -m 0755 /etc/prometheus/targets /etc/prometheus/rules

{
cat <<EOS
#!/bin/bash
# Engendre les fichiers file_sd de Prometheus depuis noeuds.yml (source unique).
set -euo pipefail
NOEUDS="$FICHIER_NOEUDS"
OUT=/etc/prometheus/targets
EOS
cat <<'EOS'
[ -r "$NOEUDS" ] || exit 0
gen() {  # \$1 = fichier, \$2 = regex sur le rôle, \$3 = port
  tr -d '\r' < "$NOEUDS" | awk -v re="$2" -v port="$3" '
    BEGIN { printf "[" }
    $1=="-" && $2==":nom:" { nom=$3 }
    $1==":ip:"             { ip=$2 }
    $1==":role:" && $2 ~ re {
      printf "%s{\"targets\":[\"%s:%s\"],\"labels\":{\"nom\":\"%s\",\"role\":\"%s\"}}", (n++ ? "," : ""), ip, port, nom, $2
    }
    END { print "]" }' > "$OUT/$1.tmp"
  chmod 0644 "$OUT/$1.tmp"
  mv "$OUT/$1.tmp" "$OUT/$1"
}
EOS
cat <<EOS
gen node.json    '.'            $PORT_NODE
gen haproxy.json '^lb'          $PORT_HAPROXY
gen redis.json   '^cache\$'      $PORT_REDIS_EXPORTER
gen postgres.json '^(bdd|replique)\$' $PORT_PG_EXPORTER
EOS
} | maj_fichier /usr/local/bin/obs-gen-targets 0755 || true
/usr/local/bin/obs-gen-targets

# Régénération périodique : ajouter un serveur (NB_APP=4 vagrant up) suffit
maj_fichier /etc/systemd/system/obs-gen-targets.service 0644 <<'EOF' || true
[Unit]
Description=Régénère les cibles Prometheus depuis noeuds.yml

[Service]
Type=oneshot
ExecStart=/usr/local/bin/obs-gen-targets
EOF
maj_fichier /etc/systemd/system/obs-gen-targets.timer 0644 <<'EOF' || true
[Unit]
Description=Régénération périodique des cibles Prometheus

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now obs-gen-targets.timer >/dev/null 2>&1

# ==========================================
# 4. Configuration de Prometheus
# ==========================================
echo "=> Configuration de Prometheus..."
# Prometheus ne doit être redémarré que si ses ARGUMENTS changent ; un changement de
# configuration ou de règles ne demande qu'un rechargement (SIGHUP), sans trou de collecte.
PROM_CONF_MODIFIE=0
PROM_ARGS_MODIFIE=0
if maj_fichier /etc/prometheus/prometheus.yml 0644 <<EOF
# Généré par obs.sh — ne pas éditer à la main
global:
  scrape_interval: ${SCRAPE_INTERVAL}
  scrape_timeout: 4s
  evaluation_interval: ${SCRAPE_INTERVAL}

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:${PORT_PROM}']

  - job_name: node
    file_sd_configs:
      - files: ['/etc/prometheus/targets/node.json']
        refresh_interval: 15s
    relabel_configs:
      - source_labels: [nom]
        target_label: instance

  - job_name: haproxy
    file_sd_configs:
      - files: ['/etc/prometheus/targets/haproxy.json']
        refresh_interval: 15s
    relabel_configs:
      - source_labels: [nom]
        target_label: instance

  - job_name: redis
    file_sd_configs:
      - files: ['/etc/prometheus/targets/redis.json']
        refresh_interval: 15s
    relabel_configs:
      - source_labels: [nom]
        target_label: instance

  - job_name: postgres
    file_sd_configs:
      - files: ['/etc/prometheus/targets/postgres.json']
        refresh_interval: 15s
    relabel_configs:
      - source_labels: [nom]
        target_label: instance
EOF
then PROM_CONF_MODIFIE=1; fi

if maj_fichier /etc/prometheus/rules/resultats-bf.yml 0644 <<'EOF'
groups:
  - name: resultats-bf
    rules:
      - alert: VmInjoignable
        expr: up{job="node"} == 0
        for: 10s
        labels: { severity: critical }
        annotations:
          summary: "La VM {{ $labels.instance }} ne répond plus"
      - alert: ServeursApplicatifsDegrades
        expr: count(up{job="node",role="app"} == 1) < count(up{job="node",role="app"})
        for: 5s
        labels: { severity: warning }
        annotations:
          summary: "Au moins un serveur applicatif est hors ligne"
      - alert: RedisInjoignable
        expr: up{job="redis"} == 0
        for: 10s
        labels: { severity: warning }
        annotations:
          summary: "Redis ne répond plus : l'application retombe sur la base"
      - alert: PostgresInjoignable
        expr: up{job="postgres"} == 0 or pg_up == 0
        for: 10s
        labels: { severity: critical }
        annotations:
          summary: "PostgreSQL ne répond plus sur {{ $labels.instance }}"
      - alert: ReplicationEnRetard
        expr: max(pg_replication_lag_seconds or pg_replication_lag) > 10
        for: 30s
        labels: { severity: warning }
        annotations:
          summary: "Le réplica a plus de 10 s de retard sur le primaire"
EOF
then PROM_CONF_MODIFIE=1; fi

install -d -o prometheus -g prometheus /var/lib/prometheus/metrics2
if maj_fichier /etc/default/prometheus 0644 <<EOF
# Généré par obs.sh
ARGS="--config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/metrics2 --storage.tsdb.retention.time=${PROM_RETENTION} --storage.tsdb.retention.size=${PROM_RETENTION_SIZE} --web.listen-address=0.0.0.0:${PORT_PROM}"
GOMEMLIMIT=200MiB
EOF
then PROM_ARGS_MODIFIE=1; fi

if command -v promtool >/dev/null 2>&1; then
  promtool check config /etc/prometheus/prometheus.yml >/dev/null \
    || { echo "❌ prometheus.yml invalide :" >&2; promtool check config /etc/prometheus/prometheus.yml >&2; exit 1; }
fi
systemctl enable prometheus >/dev/null 2>&1 || true
if [ "$PROM_ARGS_MODIFIE" -eq 1 ] || ! systemctl is-active --quiet prometheus; then
  systemctl restart prometheus
  echo "   Prometheus (re)démarré"
elif [ "$PROM_CONF_MODIFIE" -eq 1 ]; then
  systemctl reload prometheus
  echo "   configuration Prometheus rechargée (sans redémarrage)"
else
  echo "   Prometheus inchangé : ni redémarrage ni rechargement"
fi

# ==========================================
# 5. Grafana : datasource + tableau de bord en code
# ==========================================
if [ "$GRAFANA_OK" -eq 1 ] && dpkg -s grafana >/dev/null 2>&1; then
  echo "=> Configuration de Grafana..."
  GRAFANA_MODIFIE=0   # un changement de datasource/réglages impose un redémarrage ; pas un changement de tableau de bord
  install -d /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /etc/grafana/dashboards

  if maj_fichier /etc/grafana/provisioning/datasources/prometheus.yml 0644 <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://localhost:${PORT_PROM}
    isDefault: true
    editable: false
    jsonData:
      timeInterval: ${SCRAPE_INTERVAL}
EOF
  then GRAFANA_MODIFIE=1; fi

  if maj_fichier /etc/grafana/provisioning/dashboards/resultats-bf.yml 0644 <<'EOF'
apiVersion: 1
providers:
  - name: resultats-bf
    folder: RESULTATS-BF
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /etc/grafana/dashboards
EOF
  then GRAFANA_MODIFIE=1; fi

  DASH_TMP=$(mktemp)
  python3 - > "$DASH_TMP" <<'PY'
import json
import sys

DS = {"type": "prometheus", "uid": "prometheus"}
_id = [0]

def nid():
    _id[0] += 1
    return _id[0]

def targets(exprs):
    return [{"refId": chr(65 + i), "datasource": DS, "expr": e, "legendFormat": l}
            for i, (e, l) in enumerate(exprs)]

def ts(title, x, y, w, h, exprs, unit="short", desc=""):
    return {"id": nid(), "type": "timeseries", "title": title, "description": desc,
            "datasource": DS, "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "fieldConfig": {"defaults": {"unit": unit, "min": 0,
                            "custom": {"lineWidth": 2, "fillOpacity": 12, "showPoints": "never"}},
                            "overrides": []},
            "options": {"legend": {"displayMode": "list", "placement": "bottom"},
                        "tooltip": {"mode": "multi", "sort": "desc"}},
            "targets": targets(exprs)}

def stat(title, x, y, w, h, expr, steps, desc=""):
    return {"id": nid(), "type": "stat", "title": title, "description": desc,
            "datasource": DS, "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "fieldConfig": {"defaults": {"unit": "short", "decimals": 0,
                            "thresholds": {"mode": "absolute", "steps": steps}},
                            "overrides": []},
            "options": {"colorMode": "background", "graphMode": "none", "textMode": "value",
                        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
            "targets": targets([(expr, "")])}

def states(title, x, y, w, h, expr, legend):
    return {"id": nid(), "type": "state-timeline", "title": title,
            "description": "Une VM qui disparaît passe au rouge (up = 0).",
            "datasource": DS, "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "fieldConfig": {"defaults": {
                "custom": {"fillOpacity": 80, "lineWidth": 0},
                "thresholds": {"mode": "absolute", "steps": [
                    {"color": "red", "value": None}, {"color": "green", "value": 1}]},
                "mappings": [{"type": "value", "options": {
                    "0": {"text": "HORS LIGNE", "color": "red", "index": 0},
                    "1": {"text": "EN LIGNE", "color": "green", "index": 1}}}]},
                "overrides": []},
            "options": {"showValue": "never", "mergeValues": True, "rowHeight": 0.85,
                        "legend": {"showLegend": False}, "tooltip": {"mode": "single"}},
            "targets": targets([(expr, legend)])}

RED_GREEN = [{"color": "red", "value": None}, {"color": "orange", "value": 1}, {"color": "green", "value": 2}]
TOTAL = [{"color": "blue", "value": None}]

panels = [
    stat("Serveurs applicatifs en ligne", 0, 0, 4, 6,
         'count(up{job="node",role="app"} == 1) or vector(0)', RED_GREEN),
    stat("Serveurs applicatifs déclarés", 4, 0, 4, 6,
         'count(up{job="node",role="app"})', TOTAL),
    states("Disponibilité des machines virtuelles", 8, 0, 16, 6,
           'up{job="node"}', "{{instance}}"),

    ts("Débit réseau entrant par VM (octets/s)", 0, 6, 8, 8,
       [('sum by (instance) (rate(node_network_receive_bytes_total{device!="lo"}[30s]))', "{{instance}}")],
       unit="Bps", desc="Le trafic monte sur lb1 puis sur les app pendant la charge (ab)."),
    ts("Charge CPU par VM (%)", 8, 6, 8, 8,
       [('100 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[30s])) * 100', "{{instance}}")],
       unit="percent"),
    ts("Mémoire utilisée par VM (%)", 16, 6, 8, 8,
       [('100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)', "{{instance}}")],
       unit="percent"),

    ts("HAProxy — requêtes par seconde (débit)", 0, 14, 12, 8,
       [('sum(rate(haproxy_frontend_http_requests_total[30s]))', "requêtes/s"),
        ('sum(rate(haproxy_server_http_responses_total{code="5xx"}[30s]))', "erreurs 5xx/s")],
       unit="reqps", desc="Nécessite le frontend Prometheus de HAProxy (voir INTEGRATION.md)."),
    ts("HAProxy — réponses 2xx par serveur", 12, 14, 12, 8,
       [('sum by (server) (rate(haproxy_server_http_responses_total{code="2xx"}[30s]))', "{{server}}")],
       unit="reqps", desc="Montre la répartition, et un serveur qui sort puis revient."),

    ts("Redis — taux de succès du cache", 0, 22, 8, 8,
       [('rate(redis_keyspace_hits_total[30s]) / (rate(redis_keyspace_hits_total[30s]) + rate(redis_keyspace_misses_total[30s]))', "hit ratio")],
       unit="percentunit"),
    ts("Redis — commandes par seconde", 8, 22, 8, 8,
       [('rate(redis_commands_processed_total[30s])', "commandes/s")], unit="ops"),
    ts("Redis — mémoire et clés", 16, 22, 8, 8,
       [('redis_memory_used_bytes', "mémoire (octets)"),
        ('sum(redis_db_keys)', "clés")], unit="short"),

    stat("PostgreSQL en ligne", 0, 30, 4, 8,
         'count(pg_up == 1) or vector(0)', RED_GREEN,
         desc="bdd1 (primaire) + bdd2 (réplica) : 2 attendus."),
    ts("PostgreSQL — transactions par seconde", 4, 30, 10, 8,
       [('sum by (instance) (rate(pg_stat_database_xact_commit[30s]) + rate(pg_stat_database_xact_rollback[30s]))', "{{instance}}")],
       unit="ops", desc="Débit transactionnel de chaque base (le réplica ne reçoit que des lectures)."),
    ts("PostgreSQL — connexions", 14, 30, 10, 8,
       [('sum by (instance) (pg_stat_activity_count)', "{{instance}}")], unit="short"),
    ts("Réplication — retard du réplica (s)", 0, 38, 12, 8,
       [('max by (instance) (pg_replication_lag_seconds)', "{{instance}}"),
        ('max by (instance) (pg_replication_lag)', "{{instance}}")],
       unit="s", desc="0 sur le primaire ; sur le réplica : délai de rejeu des WAL."),
    ts("PostgreSQL — disponibilité (pg_up)", 12, 38, 12, 8,
       [('pg_up', "{{instance}}")], unit="short", desc="1 = l'exporter joint sa base."),
]

dash = {"uid": "resultats-bf", "title": "RÉSULTATS-BF — Supervision",
        "tags": ["resultats-bf", "vagrant"], "timezone": "browser", "editable": True,
        "schemaVersion": 39, "version": 1, "refresh": "5s",
        "time": {"from": "now-10m", "to": "now"}, "panels": panels}

json.dump(dash, sys.stdout, ensure_ascii=False, indent=1)
PY
  # Grafana relit seul ses tableaux de bord (updateIntervalSeconds) : pas de redémarrage
  maj_fichier /etc/grafana/dashboards/resultats-bf.json 0644 < "$DASH_TMP" || true
  rm -f "$DASH_TMP"

  # ATTENTION : /etc/default/grafana-server est le fichier du PAQUET. L'unité systemd y lit
  # CONF_FILE, DATA_DIR, LOG_DIR, PLUGINS_DIR, PROVISIONING_CFG_DIR et PID_FILE_DIR pour
  # construire sa ligne ExecStart. L'écraser avec de simples GF_* (ancienne version de ce
  # script) empêche Grafana de démarrer. On le répare s'il est abîmé, puis on place nos
  # réglages dans un fichier SÉPARÉ, chargé par un drop-in systemd.
  if ! grep -q '^CONF_FILE=' /etc/default/grafana-server 2>/dev/null; then
    echo "=> Réparation de /etc/default/grafana-server (valeurs d'origine du paquet)..."
    cat > /etc/default/grafana-server <<'EOF'
GRAFANA_USER=grafana
GRAFANA_GROUP=grafana
GRAFANA_HOME=/usr/share/grafana
LOG_DIR=/var/log/grafana
DATA_DIR=/var/lib/grafana
MAX_OPEN_FILES=10000
CONF_DIR=/etc/grafana
CONF_FILE=/etc/grafana/grafana.ini
RESTART_ON_UPGRADE=true
PLUGINS_DIR=/var/lib/grafana/plugins
PROVISIONING_CFG_DIR=/etc/grafana/provisioning
PID_FILE_DIR=/var/run/grafana
EOF
    chmod 0644 /etc/default/grafana-server
    GRAFANA_MODIFIE=1
  fi

  if maj_fichier /etc/grafana/obs.env 0600 <<EOF
# Généré par obs.sh
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=$(envq "$GRAFANA_PASSWORD")
GF_USERS_ALLOW_SIGN_UP=false
GF_AUTH_ANONYMOUS_ENABLED=true
GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
GF_ANALYTICS_REPORTING_ENABLED=false
GF_ANALYTICS_CHECK_FOR_UPDATES=false
GF_SERVER_HTTP_ADDR=0.0.0.0
GF_SERVER_HTTP_PORT=${PORT_GRAFANA}
GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/dashboards/resultats-bf.json
GOMEMLIMIT=200MiB
EOF
  then GRAFANA_MODIFIE=1; fi
  install -d -m 0755 /etc/systemd/system/grafana-server.service.d
  if maj_fichier /etc/systemd/system/grafana-server.service.d/obs.conf 0644 <<'EOF'
[Service]
EnvironmentFile=-/etc/grafana/obs.env
EOF
  then GRAFANA_MODIFIE=1; systemctl daemon-reload; fi

  systemctl enable grafana-server >/dev/null 2>&1 || true
  if [ "$GRAFANA_MODIFIE" -eq 1 ] || ! systemctl is-active --quiet grafana-server; then
    systemctl restart grafana-server
    echo "   Grafana (re)démarré"
  else
    echo "   Grafana inchangé : pas de redémarrage"
  fi

  # Le mot de passe admin n'est pris en compte qu'à la 1re création de la base :
  # on le réaligne à chaque provisionnement (non bloquant).
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:${PORT_GRAFANA}/api/health" >/dev/null 2>&1 && break; sleep 2; done
  if command -v grafana-cli >/dev/null 2>&1 \
     && ! curl -fs -u "admin:${GRAFANA_PASSWORD}" "http://127.0.0.1:${PORT_GRAFANA}/api/user" >/dev/null 2>&1; then
    echo "   mot de passe admin Grafana réaligné sur GRAFANA_PASSWORD"
    runuser -u grafana -- grafana-cli admin reset-admin-password "$GRAFANA_PASSWORD" >/dev/null 2>&1 || true
  fi
fi

# ==========================================
# 6. Vérifications (non bloquantes)
# ==========================================
echo "=> Vérifications..."
for _ in $(seq 1 30); do curl -fs "http://127.0.0.1:${PORT_PROM}/-/ready" >/dev/null 2>&1 && break; sleep 1; done
if curl -fs "http://127.0.0.1:${PORT_PROM}/-/ready" >/dev/null 2>&1; then
  echo "   ✅ Prometheus prêt"
else
  echo "   ⚠️  Prometheus ne répond pas : sudo journalctl -u prometheus -n 50"
fi
GRAFANA_UP=0
if [ "$GRAFANA_OK" -eq 1 ]; then
  for _ in $(seq 1 45); do   # le 1er démarrage peut dépasser 1 min sur une VM de 768 Mo
    curl -fs "http://127.0.0.1:${PORT_GRAFANA}/api/health" >/dev/null 2>&1 && { GRAFANA_UP=1; break; }
    sleep 2
  done
  if [ "$GRAFANA_UP" -eq 1 ]; then
    echo "   ✅ Grafana prêt"
  else
    echo "   ⚠️  Grafana ne répond pas (service : $(systemctl is-active grafana-server || true))"
    echo "      Dernières lignes du journal :"
    journalctl -u grafana-server -n 12 --no-pager 2>/dev/null | sed 's/^/        /' || true
  fi
fi

sleep 8   # laisse passer un ou deux cycles de collecte

if [ "$GRAFANA_UP" -eq 1 ]; then
  NB_UP=$(curl -fsG --max-time 10 --data-urlencode 'query=count(up == 1)' \
            "http://127.0.0.1:${PORT_GRAFANA}/api/datasources/proxy/uid/prometheus/api/v1/query" 2>/dev/null |
          python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["result"][0]["value"][1])' 2>/dev/null || true)
  if [ -n "$NB_UP" ]; then
    echo "   ✅ Grafana -> Prometheus : datasource opérationnelle (${NB_UP} cibles « up »)"
  else
    echo "   ⚠️  Grafana n'arrive pas à interroger Prometheus (datasource « Prometheus » : Connections > Data sources)"
  fi
fi
echo "   Cibles Prometheus :"
curl -fs "http://127.0.0.1:${PORT_PROM}/api/v1/targets" 2>/dev/null | python3 -c '
import json, sys
try:
    cibles = json.load(sys.stdin)["data"]["activeTargets"]
except Exception:
    sys.exit(0)
for c in sorted(cibles, key=lambda c: (c["labels"].get("job", ""), c["labels"].get("instance", ""))):
    icone = "✅" if c["health"] == "up" else "⚠️ "
    ligne = "     %s %-10s %-8s %s" % (icone, c["labels"].get("job", ""), c["labels"].get("instance", ""), c["scrapeUrl"])
    if c["health"] != "up":
        ligne += "\n          -> " + (c.get("lastError") or "pas encore collecté")[:90]
    print(ligne)
' || true

echo "==================================================="
echo "✅ Supervision prête !"
echo "Grafana    : http://${OBS_IP}:${PORT_GRAFANA}  (admin / GRAFANA_PASSWORD ; lecture anonyme activée)"
if [ "$GRAFANA_PW_DERIVE" -eq 1 ]; then echo "Mot de passe admin Grafana (dérivé de PG_PASSWORD) : ${GRAFANA_PASSWORD}"; fi
echo "Prometheus : http://${OBS_IP}:${PORT_PROM}"
echo "Les cibles HAProxy (:${PORT_HAPROXY}, /metrics), Redis (:${PORT_REDIS_EXPORTER}) et PostgreSQL (:${PORT_PG_EXPORTER}) apparaissent « DOWN » tant"
echo "que les VM lb1/lb2, cache, bdd1 et bdd2 ne sont pas provisionnées (scripts à jour) et démarrées."
echo "==================================================="