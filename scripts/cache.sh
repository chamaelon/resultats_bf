#!/bin/bash
# =============================================================================
#  cache.sh — Provisionnement de la VM « cache » : Redis + invalidation par événement
# -----------------------------------------------------------------------------
#  Stratégie : cache-aside côté application (clé « <préfixe><matricule> », valeur = JSON de la
#  réponse, TTL = filet de sécurité) + INVALIDATION PAR ÉVÉNEMENT :
#
#    bdd1 : trigger sur la table resultat -> pg_notify('resultat_changed', matricule)
#    cache: démon cache-invalidator (LISTEN) -> DEL de la clé concernée
#
#  - INSERT/UPDATE/DELETE : la clé concernée est supprimée immédiatement.
#  - TRUNCATE (ou rechargement massif) : payload « * » -> purge de tout le préfixe.
#  - Reconnexion au primaire (panne, bascule vers bdd2) : purge de sécurité (des notifications
#    ont pu être manquées). Le démon suit le primaire tout seul (pg_is_in_recovery() sur bdd1
#    puis bdd2) -> compatible scénario V4.
#  - Redis indisponible : le démon se marque « sale » et purge au retour de Redis.
#  - Préfixe : « resultat: » par défaut ; si CACHE_PREFIX n'a pas de « : » final, les deux
#    formes de clé (<préfixe><m> et <préfixe>:<m>) sont invalidées.
#
#  IDEMPOTENT : Redis (un cache pur : le redémarrer le VIDE) n'est redémarré que si sa
#  configuration change ; le démon et ses outils ne sont réécrits / redémarrés que s'ils changent ;
#  les triggers sont recréés à l'identique (CREATE OR REPLACE / DROP IF EXISTS).
#
#  - REDIS_PASSWORD absent du .env => dérivé de PG_PASSWORD (même valeur que sur app1..N).
#  - Redis n'écoute que sur le réseau privé (jamais d'exposition vers l'hôte).
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

echo "==================================================="
echo " Déploiement du cache Redis (invalidation par NOTIFY)"
echo "==================================================="

REDIS_PORT=$(echo "${REDIS_PORT:-6379}" | tr -d '\r')
secret_defaut REDIS_PASSWORD
REDIS_MAXMEMORY="${REDIS_MAXMEMORY:-128mb}"        # VM de 512 Mo
CACHE_TTL="${CACHE_TTL:-300}"                      # secondes (filet de sécurité)
CACHE_PREFIX="${CACHE_PREFIX:-resultat:}"
CACHE_CHANNEL="${CACHE_CHANNEL:-resultat_changed}"

PG_PORT=$(echo "${PG_PORT:-5432}" | tr -d '\r')
PG_USER="${PG_USER:-postgres}"
: "${PG_PASSWORD:?PG_PASSWORD absent : définissez-le dans le .env (racine du dépôt ou app/api/.env)}"
PG_DB="${PG_DB:-postgres}"
PGTABLE="${PGTABLE:-resultat}"

[ -r "$FICHIER_NOEUDS" ] || { echo "❌ $FICHIER_NOEUDS introuvable" >&2; exit 1; }
CACHE_IP=$(noeud_ip cache)
BDD1_IP=$(noeud_ip bdd1)
BDD2_IP=$(noeud_ip bdd2)
OBS_IP=$(noeud_ip obs)
if [ -z "$CACHE_IP" ] || [ -z "$BDD1_IP" ]; then
  echo "❌ Nœuds 'cache' et/ou 'bdd1' absents de $FICHIER_NOEUDS (voir le Vagrantfile)" >&2
  exit 1
fi
PG_HOSTS="$BDD1_IP${BDD2_IP:+,$BDD2_IP}"
RESEAU_CIDR="${CACHE_IP%.*}.0/24"
echo "cache : ${CACHE_IP}:${REDIS_PORT} | bases : ${PG_HOSTS} | réseau : ${RESEAU_CIDR}"

# ==========================================
# 1. Installation (paquets groupés)
# ==========================================
apt_installer redis-server redis-tools postgresql-client ufw python3 python3-psycopg2 python3-redis
# Les exporters sont facultatifs : leur absence ne doit pas bloquer le cache
apt_installer prometheus-node-exporter >/dev/null 2>&1 || true
if ! apt_installer prometheus-redis-exporter >/dev/null 2>&1; then
  echo "⚠️  prometheus-redis-exporter indisponible : pas de métriques Redis dans Grafana"
fi

# ==========================================
# 2. Pare-feu
# ==========================================
echo "=> Configuration du pare-feu UFW..."
ufw allow ssh >/dev/null
ufw allow from "$RESEAU_CIDR" to any port "$REDIS_PORT" proto tcp >/dev/null
if [ -n "$OBS_IP" ]; then
  ufw allow from "$OBS_IP" to any port 9121 proto tcp >/dev/null
  ufw allow from "$OBS_IP" to any port 9100 proto tcp >/dev/null
fi
ufw --force enable >/dev/null

# ==========================================
# 3. Configuration de Redis (fichier complet, déterministe)
# ==========================================
echo "=> Configuration de Redis..."
sysctl -w vm.overcommit_memory=1 >/dev/null
echo 'vm.overcommit_memory = 1' | maj_fichier /etc/sysctl.d/99-redis.conf 0644 || true

[ -f /etc/redis/redis.conf.orig ] || cp /etc/redis/redis.conf /etc/redis/redis.conf.orig
# Redis est un cache pur : le redémarrer le VIDE. On ne le redémarre donc que si sa
# configuration change réellement (ou s'il est arrêté), jamais sur un simple rejeu.
REDIS_MODIFIE=0
if maj_fichier /etc/redis/redis.conf 0640 redis:redis <<EOF
# Généré par cache.sh — ne pas éditer à la main
# Écoute sur le réseau privé uniquement (jamais d'exposition vers l'hôte — R8)
bind 127.0.0.1 ${CACHE_IP}
port ${REDIS_PORT}
protected-mode yes
requirepass $(envq "$REDIS_PASSWORD")
tcp-keepalive 60
timeout 0

daemonize no
supervised systemd
pidfile /run/redis/redis-server.pid
loglevel notice
logfile /var/log/redis/redis-server.log
dir /var/lib/redis

# Pur cache : pas de persistance, éviction LRU quand la mémoire est pleine
save ""
appendonly no
maxmemory ${REDIS_MAXMEMORY}
maxmemory-policy allkeys-lru

latency-monitor-threshold 100
EOF
then REDIS_MODIFIE=1; fi

systemctl enable redis-server >/dev/null 2>&1 || true
if [ "$REDIS_MODIFIE" -eq 1 ] || ! systemctl is-active --quiet redis-server; then
  systemctl restart redis-server
  echo "   Redis (re)démarré"
else
  echo "   configuration Redis inchangée : pas de redémarrage (le cache est conservé)"
fi

export REDISCLI_AUTH="$REDIS_PASSWORD"
for _ in $(seq 1 30); do
  [ "$(redis-cli -h 127.0.0.1 -p "$REDIS_PORT" ping 2>/dev/null || true)" = "PONG" ] && break
  sleep 1
done
[ "$(redis-cli -h 127.0.0.1 -p "$REDIS_PORT" ping 2>/dev/null || true)" = "PONG" ] \
  || { echo "❌ Redis ne répond pas : sudo journalctl -u redis-server -n 50" >&2; exit 1; }

# Exporter Prometheus (le mot de passe passe par l'environnement, pas par la ligne de commande)
if dpkg -s prometheus-redis-exporter >/dev/null 2>&1; then
  EXPORTER_MODIFIE=0
  if maj_fichier /etc/default/prometheus-redis-exporter 0640 <<EOF
# Généré par cache.sh
ARGS="--web.listen-address=:9121"
REDIS_ADDR=redis://127.0.0.1:${REDIS_PORT}
REDIS_PASSWORD=$(envq "$REDIS_PASSWORD")
EOF
  then EXPORTER_MODIFIE=1; fi
  chgrp prometheus /etc/default/prometheus-redis-exporter 2>/dev/null || true
  systemctl enable prometheus-redis-exporter >/dev/null 2>&1 || true
  if [ "$EXPORTER_MODIFIE" -eq 1 ] || ! systemctl is-active --quiet prometheus-redis-exporter; then
    systemctl restart prometheus-redis-exporter || echo "⚠️  prometheus-redis-exporter n'a pas démarré"
  fi
fi
systemctl enable --now prometheus-node-exporter >/dev/null 2>&1 || true

# ==========================================
# 4. Trigger de notification sur le primaire PostgreSQL
# ==========================================
primaire() {  # affiche l'IP de celle des bases qui n'est PAS en recovery
  local h r
  for h in ${PG_HOSTS//,/ }; do
    r=$(PGPASSWORD="$PG_PASSWORD" PGCONNECT_TIMEOUT=3 psql -h "$h" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
          -tAc "SELECT NOT pg_is_in_recovery()" 2>/dev/null || true)
    if [ "$r" = "t" ]; then echo "$h"; return 0; fi
  done
  return 1
}
psql_primaire() {
  PGPASSWORD="$PG_PASSWORD" PGCONNECT_TIMEOUT=5 psql -h "$PRIMAIRE" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
    -v ON_ERROR_STOP=1 "$@"
}

echo "=> Recherche du primaire PostgreSQL (bdd1 doit être provisionnée)..."
PRIMAIRE=""
for _ in $(seq 1 60); do
  PRIMAIRE=$(primaire || true)
  [ -n "$PRIMAIRE" ] && break
  sleep 2
done

TRIGGER_OK=0
if [ -z "$PRIMAIRE" ]; then
  echo "⚠️  Aucun primaire joignable : trigger non installé. Lancez 'vagrant up bdd1' puis 'vagrant provision cache'." >&2
else
  echo "   Primaire : ${PRIMAIRE}"
  for _ in $(seq 1 30); do   # attend que bdd1.sh ait créé la table
    [ "$(psql_primaire -tAc "SELECT to_regclass('public.${PGTABLE}') IS NOT NULL" 2>/dev/null || true)" = "t" ] && break
    sleep 2
  done
  echo "=> Installation du trigger de notification sur ${PGTABLE}..."
  if psql_primaire -q >/dev/null <<SQL
BEGIN;
CREATE OR REPLACE FUNCTION notify_${PGTABLE}_change() RETURNS trigger
LANGUAGE plpgsql AS \$fn\$
BEGIN
  IF TG_OP = 'TRUNCATE' THEN
    PERFORM pg_notify('${CACHE_CHANNEL}', '*');
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM pg_notify('${CACHE_CHANNEL}', OLD.matricule_candidat::text);
  ELSIF TG_OP = 'UPDATE' THEN
    PERFORM pg_notify('${CACHE_CHANNEL}', OLD.matricule_candidat::text);
    IF NEW.matricule_candidat IS DISTINCT FROM OLD.matricule_candidat THEN
      PERFORM pg_notify('${CACHE_CHANNEL}', NEW.matricule_candidat::text);
    END IF;
  ELSE
    PERFORM pg_notify('${CACHE_CHANNEL}', NEW.matricule_candidat::text);
  END IF;
  RETURN NULL;
END
\$fn\$;

DROP TRIGGER IF EXISTS ${PGTABLE}_cache_row ON ${PGTABLE};
CREATE TRIGGER ${PGTABLE}_cache_row
  AFTER INSERT OR UPDATE OR DELETE ON ${PGTABLE}
  FOR EACH ROW EXECUTE FUNCTION notify_${PGTABLE}_change();

DROP TRIGGER IF EXISTS ${PGTABLE}_cache_trunc ON ${PGTABLE};
CREATE TRIGGER ${PGTABLE}_cache_trunc
  AFTER TRUNCATE ON ${PGTABLE}
  FOR EACH STATEMENT EXECUTE FUNCTION notify_${PGTABLE}_change();
COMMIT;
SQL
  then
    TRIGGER_OK=1
    echo "   ✅ Triggers installés (répliqués automatiquement sur bdd2)"
  else
    echo "⚠️  Installation du trigger impossible (table absente ou droits insuffisants pour ${PG_USER})." >&2
    echo "   L'invalidation par TTL (${CACHE_TTL}s) reste active ; relancez 'vagrant provision cache' après bdd1." >&2
  fi
fi

# ==========================================
# 5. Démon d'invalidation (LISTEN PostgreSQL -> DEL Redis)
# ==========================================
echo "=> Installation du démon cache-invalidator..."
install -d -m 0755 /usr/local/lib/cache-invalidator

INV_MODIFIE=0     # code, environnement ou unité du démon modifiés => redémarrage nécessaire
if maj_fichier /usr/local/lib/cache-invalidator/invalidator.py 0644 <<'PY'
#!/usr/bin/env python3
"""Invalide le cache Redis à chaque modification signalée par PostgreSQL (LISTEN/NOTIFY)."""
import logging
import os
import re
import select
import signal
import sys
import time

import psycopg2
import redis

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
log = logging.getLogger("cache-invalidator")

PG_HOSTS = [h.strip() for h in os.environ["PG_HOSTS"].split(",") if h.strip()]
PG_PORT = int(os.environ.get("PG_PORT", "5432"))
PG_USER = os.environ["PG_USER"]
PG_PASSWORD = os.environ["PG_PASSWORD"]
PG_DB = os.environ["PG_DB"]
CHANNEL = os.environ.get("CACHE_CHANNEL", "resultat_changed")
PREFIX = os.environ.get("CACHE_PREFIX", "resultat:")
if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", CHANNEL):
    sys.exit("CACHE_CHANNEL invalide")

r = redis.Redis(host=os.environ.get("REDIS_HOST", "127.0.0.1"),
                port=int(os.environ.get("REDIS_PORT", "6379")),
                password=os.environ.get("REDIS_PASSWORD") or None,
                socket_timeout=3, socket_connect_timeout=3, decode_responses=True)

dirty = False  # vrai si une invalidation n'a pas pu être appliquée (Redis indisponible)


def bye(*_):
    log.info("arrêt demandé")
    sys.exit(0)


signal.signal(signal.SIGTERM, bye)
signal.signal(signal.SIGINT, bye)


def flush_prefix(raison):
    """Supprime toutes les clés du préfixe (SCAN + UNLINK, sans bloquer Redis)."""
    global dirty
    try:
        total, lot = 0, []
        for cle in r.scan_iter(match=PREFIX + "*", count=500):
            lot.append(cle)
            if len(lot) >= 500:
                total += r.unlink(*lot)
                lot = []
        if lot:
            total += r.unlink(*lot)
        r.hincrby("cache:stats", "purges", 1)
        dirty = False
        log.info("purge du préfixe '%s' (%s) : %d clé(s)", PREFIX, raison, total)
    except redis.RedisError as e:
        dirty = True
        log.error("purge impossible (%s) : %s", raison, e)


def invalider(payload):
    global dirty
    if payload == "*":
        flush_prefix("TRUNCATE / rechargement")
        return
    cles = [PREFIX + payload]
    if not PREFIX.endswith(":"):
        cles.append(PREFIX + ":" + payload)    # l'application peut utiliser « préfixe:matricule »
    try:
        n = r.delete(*cles)
        r.hincrby("cache:stats", "invalidations", 1)
        log.info("invalidation %s%s (%d clé(s) supprimée(s))", PREFIX, payload, n)
    except redis.RedisError as e:
        dirty = True
        log.error("invalidation de %s impossible : %s", payload, e)


def connecter_primaire():
    """Se connecte à la base qui n'est pas en recovery (bdd1, ou bdd2 après promotion)."""
    for hote in PG_HOSTS:
        try:
            conn = psycopg2.connect(host=hote, port=PG_PORT, user=PG_USER, password=PG_PASSWORD,
                                    dbname=PG_DB, connect_timeout=5, application_name="cache-invalidator",
                                    keepalives=1, keepalives_idle=10, keepalives_interval=5, keepalives_count=3)
            conn.autocommit = True
            cur = conn.cursor()
            cur.execute("SELECT pg_is_in_recovery()")
            if cur.fetchone()[0]:
                conn.close()          # réplica : LISTEN y est impossible
                continue
            cur.execute("LISTEN " + CHANNEL)
            return conn, hote
        except Exception as e:        # noqa: BLE001 — on réessaie avec l'hôte suivant
            log.warning("connexion à %s impossible : %s", hote, e)
    return None, None


attente = 1
while True:
    conn, hote = connecter_primaire()
    if conn is None:
        time.sleep(attente)
        attente = min(attente * 2, 10)
        continue
    attente = 1
    log.info("à l'écoute du canal '%s' sur %s", CHANNEL, hote)
    # Des notifications ont pu être perdues pendant la coupure : purge de sécurité.
    flush_prefix("(re)connexion au primaire")
    try:
        while True:
            if dirty:
                flush_prefix("rattrapage après indisponibilité de Redis")
            if select.select([conn], [], [], 15) == ([], [], []):
                conn.cursor().execute("SELECT 1")   # détecte une connexion morte
                continue
            conn.poll()
            while conn.notifies:
                invalider(conn.notifies.pop(0).payload)
    except Exception as e:                           # noqa: BLE001
        log.error("connexion perdue (%s) : reconnexion...", e)
        try:
            conn.close()
        except Exception:                            # noqa: BLE001
            pass
        time.sleep(1)
PY
then INV_MODIFIE=1; fi
python3 -m py_compile /usr/local/lib/cache-invalidator/invalidator.py
rm -rf /usr/local/lib/cache-invalidator/__pycache__

if maj_fichier /etc/cache-invalidator.env 0600 <<EOF
PG_HOSTS=${PG_HOSTS}
PG_PORT=${PG_PORT}
PG_USER=$(envq "$PG_USER")
PG_PASSWORD=$(envq "$PG_PASSWORD")
PG_DB=$(envq "$PG_DB")
REDIS_HOST=127.0.0.1
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=$(envq "$REDIS_PASSWORD")
CACHE_PREFIX=${CACHE_PREFIX}
CACHE_CHANNEL=${CACHE_CHANNEL}
EOF
then INV_MODIFIE=1; fi

UNITE_MODIFIEE=0
if maj_fichier /etc/systemd/system/cache-invalidator.service 0644 <<'EOF'
[Unit]
Description=Invalidation du cache Redis (PostgreSQL LISTEN/NOTIFY)
After=network-online.target redis-server.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/cache-invalidator.env
ExecStart=/usr/bin/python3 -u /usr/local/lib/cache-invalidator/invalidator.py
Restart=always
RestartSec=3
TimeoutStopSec=5
DynamicUser=yes
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
then UNITE_MODIFIEE=1; INV_MODIFIE=1; fi
if [ "$UNITE_MODIFIEE" -eq 1 ]; then systemctl daemon-reload; fi
systemctl enable cache-invalidator >/dev/null 2>&1
# Redémarrer le démon purge le cache (purge de sécurité à la connexion) : seulement si besoin.
if [ "$INV_MODIFIE" -eq 1 ] || ! systemctl is-active --quiet cache-invalidator; then
  systemctl restart cache-invalidator
  echo "   cache-invalidator (re)démarré"
else
  echo "   cache-invalidator inchangé : pas de redémarrage"
fi

# ==========================================
# 6. Outils d'exploitation (sudo cache-stats, cache-flush, cache-invalidate)
# ==========================================
echo "=> Installation des outils cache-stats / cache-flush / cache-invalidate..."
{
  printf 'REDIS_PORT=%q\n' "$REDIS_PORT"
  printf 'REDIS_PASSWORD=%q\n' "$REDIS_PASSWORD"
  printf 'CACHE_PREFIX=%q\n' "$CACHE_PREFIX"
  printf 'CACHE_TTL=%q\n' "$CACHE_TTL"
} | maj_fichier /etc/cache-tools.env 0600 || true

maj_fichier /usr/local/bin/cache-stats 0755 <<'EOS' || true
#!/bin/bash
# Usage : sudo cache-stats [--reset]   (--reset remet les compteurs à zéro avant un test de charge)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
set -a; source /etc/cache-tools.env; set +a
export REDISCLI_AUTH="$REDIS_PASSWORD"
rc() { redis-cli -h 127.0.0.1 -p "$REDIS_PORT" "$@"; }
if [ "${1:-}" = "--reset" ]; then rc CONFIG RESETSTAT >/dev/null; rc DEL cache:stats >/dev/null; echo "Compteurs remis à zéro."; exit 0; fi
INFO=$( { rc INFO stats; rc INFO memory; } | tr -d '\r')
val() { printf '%s\n' "$INFO" | awk -F: -v k="$1" '$1==k {print $2}'; }
H=$(val keyspace_hits); M=$(val keyspace_misses)
RATIO=$(awk -v h="${H:-0}" -v m="${M:-0}" 'BEGIN { t=h+m; if (t>0) printf "%.1f %%", 100*h/t; else print "n/a" }')
INV=$(rc HGET cache:stats invalidations | tr -d '\r'); PUR=$(rc HGET cache:stats purges | tr -d '\r')
echo "Succès (hits)        : ${H:-0}"
echo "Échecs (misses)      : ${M:-0}"
echo "Taux de succès       : ${RATIO}"
echo "Clés ${CACHE_PREFIX}*       : $(rc --scan --pattern "${CACHE_PREFIX}*" | wc -l)"
echo "Mémoire              : $(val used_memory_human) / max $(val maxmemory_human)"
echo "Évictions / expirées : $(val evicted_keys) / $(val expired_keys)"
echo "Invalidations NOTIFY : ${INV:-0} (purges totales : ${PUR:-0})"
echo "Débit instantané     : $(val instantaneous_ops_per_sec) ops/s | TTL appli : ${CACHE_TTL}s"
EOS

maj_fichier /usr/local/bin/cache-flush 0755 <<'EOS' || true
#!/bin/bash
# Usage : sudo cache-flush     (supprime toutes les clés du préfixe, sans bloquer Redis)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
set -a; source /etc/cache-tools.env; set +a
export REDISCLI_AUTH="$REDIS_PASSWORD"
N=$(redis-cli -h 127.0.0.1 -p "$REDIS_PORT" --scan --pattern "${CACHE_PREFIX}*" |
    xargs -r -n 500 redis-cli -h 127.0.0.1 -p "$REDIS_PORT" UNLINK | awk '{s+=$1} END {print s+0}')
echo "${N} clé(s) supprimée(s)."
EOS

maj_fichier /usr/local/bin/cache-invalidate 0755 <<'EOS' || true
#!/bin/bash
# Usage : sudo cache-invalidate <matricule> [<matricule> ...]
set -euo pipefail
[ "$#" -ge 1 ] || { echo "Usage : sudo cache-invalidate <matricule>..." >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
set -a; source /etc/cache-tools.env; set +a
export REDISCLI_AUTH="$REDIS_PASSWORD"
for m in "$@"; do
  echo "${CACHE_PREFIX}${m} : $(redis-cli -h 127.0.0.1 -p "$REDIS_PORT" DEL "${CACHE_PREFIX}${m}") clé(s) supprimée(s)"
done
EOS
chmod 0755 /usr/local/bin/cache-stats /usr/local/bin/cache-flush /usr/local/bin/cache-invalidate

# ==========================================
# 7. Vérifications (non bloquantes)
# ==========================================
echo "=> Vérifications..."
RC() { redis-cli -h 127.0.0.1 -p "$REDIS_PORT" "$@"; }
if [ "$(RC SET "${CACHE_PREFIX}__test__" '{"ok":true}' EX 60 2>/dev/null || true)" = "OK" ] \
   && [ "$(RC GET "${CACHE_PREFIX}__test__")" = '{"ok":true}' ]; then
  echo "   ✅ Redis : écriture/lecture OK (maxmemory ${REDIS_MAXMEMORY}, politique allkeys-lru)"
else
  echo "   ⚠️  Redis : test d'écriture en échec"
fi

systemctl is-active --quiet cache-invalidator \
  && echo "   ✅ Démon cache-invalidator actif" \
  || echo "   ⚠️  cache-invalidator inactif : sudo journalctl -u cache-invalidator -n 50"

if [ "$TRIGGER_OK" -eq 1 ]; then
  sleep 3   # laisse le démon se connecter (et purger) avant le test de bout en bout
  RC SET "${CACHE_PREFIX}__test__" 'a-invalider' EX 60 >/dev/null
  psql_primaire -qtAc "SELECT pg_notify('${CACHE_CHANNEL}', '__test__')" >/dev/null 2>&1 || true
  OK=0
  for _ in $(seq 1 10); do
    if [ "$(RC EXISTS "${CACHE_PREFIX}__test__")" = "0" ]; then OK=1; break; fi
    sleep 1
  done
  if [ "$OK" -eq 1 ]; then
    echo "   ✅ Invalidation de bout en bout OK (NOTIFY -> DEL en moins de 10 s)"
  else
    echo "   ⚠️  La clé de test n'a pas été invalidée : sudo journalctl -u cache-invalidator -n 50"
  fi
fi

echo "==================================================="
echo "✅ Cache prêt !"
echo "Redis : ${CACHE_IP}:${REDIS_PORT} | TTL conseillé côté appli : ${CACHE_TTL}s | préfixe : ${CACHE_PREFIX}"
echo "Outils : sudo cache-stats [--reset] | sudo cache-flush | sudo cache-invalidate <matricule>"
echo "Logs   : sudo journalctl -u cache-invalidator -f"
echo "==================================================="