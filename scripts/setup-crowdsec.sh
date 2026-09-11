#!/usr/bin/env bash
# Setup CrowdSec intrusion detection + firewall bouncer
#
# Usage:
#   ./deploy/scripts/setup-crowdsec.sh
#
# Prerequisites:
#   - S1-S4 deployed (Prometheus + Grafana + Loki + Alertmanager running)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "Creating CrowdSec directories..."
mkdir -p monitoring/crowdsec

echo "Copying configuration files..."
cp monitoring/crowdsec/acquis.yaml monitoring/crowdsec/acquis.yaml
cp monitoring/crowdsec/profiles.yaml monitoring/crowdsec/profiles.yaml
cp monitoring/prometheus/prometheus.yml monitoring/prometheus/prometheus.yml

echo "Starting CrowdSec and bouncer..."
docker compose -f compose.yml -f monitoring/compose.monitoring.yml up -d crowdsec crowdsec-firewall-bouncer

echo "Waiting for CrowdSec to initialize..."
sleep 15

echo "Checking CrowdSec metrics..."
docker compose -f compose.yml -f monitoring/compose.monitoring.yml exec crowdsec cscli metrics

echo ""
echo "Checking bouncers..."
docker compose -f compose.yml -f monitoring/compose.monitoring.yml exec crowdsec cscli bouncers list

echo ""
echo "CrowdSec deployed."
echo " - SSH bruteforce → ban 4h"
echo " - HTTP scan → ban 1h"
echo " - Bad user-agent → ban 2h"
echo " - 3 bans → ban permanent (720h)"
echo ""
echo "Voir aussi les métriques sur https://monitoring.bachelart.fr (Prometheus datasource)"