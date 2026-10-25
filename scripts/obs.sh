#!/bin/bash
# =============================================================================
#  obs.sh — Extension E2 : observabilité (Prometheus + Grafana) sur la VM "obs"
# -----------------------------------------------------------------------------
#  - Prometheus collecte toutes les 5 s : node_exporter de CHAQUE VM, HAProxy
#    (lb1/lb2, port 8404) et Redis (cache, port 9121).
#  - Les cibles sont ENGENDRÉES depuis /vagrant/config/noeuds.yml (même source
#    de vérité que le Vagrantfile) : NB_APP=4 vagrant up => nouvelles cibles
#    sans toucher à la configuration (un timer les régénère toutes les 30 s).
#  - Grafana est provisionné en code : datasource + tableau de bord
#    "RÉSULTATS-BF — Supervision" (débit, CPU, disponibilité, HAProxy, Redis).
#  - Idempotent : rejouable à volonté (vagrant provision obs).
#  - Accès depuis l'hôte, SANS redirection de port (R8) :
#        Grafana    http://<RESEAU>.41:3000
#        Prometheus http://<RESEAU>.41:9090
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"
export DEBIAN_FRONTEND=noninteractive

echo "==================================================="
echo " Déploiement de la supervision (Prometheus + Grafana)"
echo "==================================================="

# --- Variables (.env synchronisé via /vagrant, jamais versionné — R7) ---
if [ -f /vagrant/app/api/.env ]; then
  set -a
  # shellcheck disable=SC1091
  source <(tr -d '\r' < /vagrant/app/api/.env)
  set +a
fi

FICHIER_NOEUDS="/vagrant/config/noeuds.yml"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"       # à surcharger dans .env
PROM_RETENTION="${PROM_RETENTION:-6h}"              # démo : 6 h suffisent
PROM_RETENTION_SIZE="${PROM_RETENTION_SIZE:-300MB}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-5s}"
PORT_PROM=9090
PORT_GRAFANA=3000
PORT_NODE=9100
PORT_HAPROXY="${PORT_HAPROXY:-8404}"
PORT_REDIS_EXPORTER=9121

[ -r "$FICHIER_NOEUDS" ] || { echo "❌ $FICHIER_NOEUDS introuvable" >&2; exit 1; }

# IP d'un nœud lue dans noeuds.yml (généré par le Vagrantfile)
noeud_ip() {
  tr -d '\r' < "$FICHIER_NOEUDS" |
    awk -v n="$1" '$1=="-" && $2==":nom:" {cur=$3} $1==":ip:" && cur==n {print $2; exit}'
}
OBS_IP=$(noeud_ip obs)
if [ -z "$OBS_IP" ]; then
  echo "❌ Le nœud 'obs' est absent de $FICHIER_NOEUDS (voir le Vagrantfile)" >&2
  exit 1
fi
RESEAU_CIDR="${OBS_IP%.*}.0/24"
echo "obs : ${OBS_IP} | réseau privé : ${RESEAU_CIDR}"

# Valeur entre guillemets pour un fichier d'environnement systemd
envq() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"; }

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
echo "=> Installation de Prometheus, node_exporter et des outils..."
apt-get update -y
apt-get install -y --no-install-recommends prometheus prometheus-node-exporter \
  curl gnupg ca-certificates ufw python3
systemctl enable --now prometheus-node-exporter >/dev/null 2>&1 || true

GRAFANA_OK=1
if ! dpkg -s grafana >/dev/null 2>&1; then
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

cat > /usr/local/bin/obs-gen-targets <<EOS
#!/bin/bash
# Engendre les fichiers file_sd de Prometheus depuis noeuds.yml (source unique).
set -euo pipefail
NOEUDS="$FICHIER_NOEUDS"
OUT=/etc/prometheus/targets
EOS
cat >> /usr/local/bin/obs-gen-targets <<'EOS'
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
cat >> /usr/local/bin/obs-gen-targets <<EOS
gen node.json    '.'            $PORT_NODE
gen haproxy.json '^lb'          $PORT_HAPROXY
gen redis.json   '^cache\$'      $PORT_REDIS_EXPORTER
EOS
chmod 0755 /usr/local/bin/obs-gen-targets
/usr/local/bin/obs-gen-targets

# Régénération périodique : ajouter un serveur (NB_APP=4 vagrant up) suffit
cat > /etc/systemd/system/obs-gen-targets.service <<'EOF'
[Unit]
Description=Régénère les cibles Prometheus depuis noeuds.yml

[Service]
Type=oneshot
ExecStart=/usr/local/bin/obs-gen-targets
EOF
cat > /etc/systemd/system/obs-gen-targets.timer <<'EOF'
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
cat > /etc/prometheus/prometheus.yml <<EOF
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
EOF

cat > /etc/prometheus/rules/resultats-bf.yml <<'EOF'
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
EOF

install -d -o prometheus -g prometheus /var/lib/prometheus/metrics2
cat > /etc/default/prometheus <<EOF
# Généré par obs.sh
ARGS="--config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/metrics2 --storage.tsdb.retention.time=${PROM_RETENTION} --storage.tsdb.retention.size=${PROM_RETENTION_SIZE} --web.listen-address=0.0.0.0:${PORT_PROM}"
GOMEMLIMIT=200MiB
EOF

if command -v promtool >/dev/null 2>&1; then
  promtool check config /etc/prometheus/prometheus.yml >/dev/null \
    || { echo "❌ prometheus.yml invalide :" >&2; promtool check config /etc/prometheus/prometheus.yml >&2; exit 1; }
fi
systemctl enable prometheus >/dev/null 2>&1 || true
systemctl restart prometheus

# ==========================================
# 5. Grafana : datasource + tableau de bord en code
# ==========================================
if [ "$GRAFANA_OK" -eq 1 ] && dpkg -s grafana >/dev/null 2>&1; then
  echo "=> Configuration de Grafana..."
  install -d /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /etc/grafana/dashboards

  cat > /etc/grafana/provisioning/datasources/prometheus.yml <<EOF
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

  cat > /etc/grafana/provisioning/dashboards/resultats-bf.yml <<'EOF'
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

  python3 - <<'PY'
import json

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
]

dash = {"uid": "resultats-bf", "title": "RÉSULTATS-BF — Supervision",
        "tags": ["resultats-bf", "vagrant"], "timezone": "browser", "editable": True,
        "schemaVersion": 39, "version": 1, "refresh": "5s",
        "time": {"from": "now-10m", "to": "now"}, "panels": panels}

with open("/etc/grafana/dashboards/resultats-bf.json", "w", encoding="utf-8") as f:
    json.dump(dash, f, ensure_ascii=False, indent=1)
PY

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
  fi

  ( umask 077
    cat > /etc/grafana/obs.env <<EOF
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
  )
  install -d -m 0755 /etc/systemd/system/grafana-server.service.d
  cat > /etc/systemd/system/grafana-server.service.d/obs.conf <<'EOF'
[Service]
EnvironmentFile=-/etc/grafana/obs.env
EOF

  systemctl daemon-reload
  systemctl enable grafana-server >/dev/null 2>&1 || true
  systemctl restart grafana-server

  # Le mot de passe admin n'est pris en compte qu'à la 1re création de la base :
  # on le réaligne à chaque provisionnement (non bloquant).
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:${PORT_GRAFANA}/api/health" >/dev/null 2>&1 && break; sleep 2; done
  if command -v grafana-cli >/dev/null 2>&1; then
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
echo "Grafana    : http://${OBS_IP}:${PORT_GRAFANA}  (admin / \$GRAFANA_PASSWORD ; lecture anonyme activée)"
echo "Prometheus : http://${OBS_IP}:${PORT_PROM}"
echo "Les cibles HAProxy (:${PORT_HAPROXY}, /metrics) et Redis (:${PORT_REDIS_EXPORTER}) apparaissent « DOWN » tant que"
echo "lb1 n'est pas (re)provisionnée avec lb.sh à jour et que la VM cache n'est pas démarrée."
echo "==================================================="