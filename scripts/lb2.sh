#!/bin/bash
# =====================================================================
#  lb2.sh — Répartiteur de secours lb2 (extension E1)
#
#  lb2 doit servir EXACTEMENT les mêmes serveurs que lb1 : il exécute donc
#  le même script HAProxy (lb.sh), qui lit la liste dans noeuds.yml.
#  Une seule copie à maintenir : aucune divergence possible entre lb1 et lb2.
#  keepalived (VRRP, IP virtuelle) est configuré ensuite par keepalived.sh.
# =====================================================================
set -euo pipefail
exec bash /vagrant/scripts/lb.sh
