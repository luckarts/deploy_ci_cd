#!/usr/bin/env bash
# Setup monitoring stack (Prometheus + Node Exporter + cAdvisor)
#
# Usage:
#   ./deploy/scripts/setup-monitoring.sh
#
# Prerequisites:
#   - Traefik must be running (for metrics endpoint + reverse proxy)
#   - DNS record monitoring.bachelart.fr pointing to the server

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "Creating monitoring directories..."
mkdir -p monitoring/prometheus/rules

echo "Copying Prometheus configuration..."
cp monitoring/prometheus/prometheus.yml monitoring/prometheus/prometheus.yml
cp monitoring/prometheus/rules/alerts.yml monitoring/prometheus/rules/alerts.yml

echo "Starting monitoring stack..."
docker compose -f compose.yml -f monitoring/compose.monitoring.yml up -d

echo "Waiting for targets to become healthy..."
sleep 10

echo "Checking Prometheus targets..."
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool 2>/dev/null || \
  echo "Prometheus not yet reachable — check 'docker compose logs prometheus'"

echo ""
echo "Monitoring stack deployed."
echo "Prometheus: https://monitoring.bachelart.fr"
echo ""
echo "To check all targets are up:"
echo "  curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[].health'"