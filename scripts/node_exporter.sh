
#!/usr/bin/env bash
set -euo pipefail

# Installation et démarrage de Node Exporter pour Prometheus.
# Script idempotent : peut être exécuté plusieurs fois.

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -E bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y prometheus-node-exporter

systemctl enable prometheus-node-exporter
systemctl restart prometheus-node-exporter

if systemctl is-active --quiet prometheus-node-exporter; then
    echo "Node Exporter est actif sur le port 9100."
else
    echo "ERREUR : Node Exporter n'a pas démarré." >&2
    exit 1
fi
