#!/bin/sh
# Entrypoint wrapper that substitutes environment variables in alertmanager.yml
# before starting Alertmanager.

set -e

CONFIG_FILE="/etc/alertmanager/alertmanager.yml"
TEMPLATE_FILE="/etc/alertmanager/alertmanager.template.yml"

if [ -f "$TEMPLATE_FILE" ]; then
  # Install envsubst if not available (gettext package)
  if ! command -v envsubst >/dev/null 2>&1; then
    apk add --no-cache gettext >/dev/null 2>&1
  fi
  echo "Substituting environment variables in Alertmanager config..."
  envsubst < "$TEMPLATE_FILE" > "$CONFIG_FILE"
fi

exec alertmanager "$@"