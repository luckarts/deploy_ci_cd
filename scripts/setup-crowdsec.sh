#!/usr/bin/env bash
# Setup CrowdSec intrusion detection + firewall bouncer natif
#
# crowdsec (détection) tourne en container ; cs-firewall-bouncer
# (bannissement iptables/nftables) tourne en paquet natif sur l'hôte —
# CrowdSec ne publie pas d'image Docker officielle pour ce bouncer, car
# il doit manipuler le pare-feu de l'hôte directement.
#
# Usage:
#   sudo ./deploy/scripts/setup-crowdsec.sh
#
# Prérequis:
#   - monitoring/.env.monitoring rempli
#   - ./scripts/deploy.sh monitoring déjà lancé une première fois (ou ce
#     script le lance lui-même à l'étape 1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ Ce script installe un paquet système — lance-le avec sudo." >&2
  exit 1
fi

echo "🚀 Démarrage du container CrowdSec (détection)..."
docker compose -f monitoring/compose.monitoring.yml --env-file monitoring/.env.monitoring up -d crowdsec

echo "⏳ Attente de l'initialisation de CrowdSec..."
sleep 10

echo "📊 Métriques CrowdSec :"
docker compose -f monitoring/compose.monitoring.yml exec crowdsec cscli metrics

echo ""
echo "🔑 Génération de la clé API pour le bouncer natif..."
BOUNCER_KEY="$(docker compose -f monitoring/compose.monitoring.yml exec -T crowdsec \
  cscli bouncers add firewall-bouncer -o raw)"

if [ -z "$BOUNCER_KEY" ]; then
  echo "❌ Échec génération de la clé API (le bouncer existe peut-être déjà :" >&2
  echo "   cscli bouncers list / cscli bouncers delete firewall-bouncer)" >&2
  exit 1
fi

echo "📦 Installation du paquet cs-firewall-bouncer (dépôt officiel CrowdSec)..."
if ! command -v cs-firewall-bouncer >/dev/null 2>&1; then
  curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
  apt-get install -y crowdsec-firewall-bouncer-iptables
fi

echo "⚙️  Configuration du bouncer natif (LAPI via 127.0.0.1:8080)..."
CONF=/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
sed -i "s#^api_url:.*#api_url: http://127.0.0.1:8080/#" "$CONF"
sed -i "s#^api_key:.*#api_key: ${BOUNCER_KEY}#" "$CONF"

systemctl restart crowdsec-firewall-bouncer
systemctl enable crowdsec-firewall-bouncer

echo ""
echo "🔎 Vérification :"
docker compose -f monitoring/compose.monitoring.yml exec crowdsec cscli bouncers list
systemctl status crowdsec-firewall-bouncer --no-pager -l | head -10

echo ""
echo "✅ CrowdSec déployé (détection en container + bouncer natif systemd)."
echo " - SSH bruteforce → ban 4h"
echo " - HTTP scan → ban 1h"
echo " - Bad user-agent → ban 2h"
echo " - 3 bans → ban permanent (720h)"
echo ""
echo "Métriques CrowdSec dans Grafana via le datasource Prometheus."
