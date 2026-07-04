#!/usr/bin/env bash
# Generates writable Grafana provisioning from the immutable source tree and
# starts a LAN dashboard using the configured PostgreSQL and HTTP ports.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$SCRIPT_DIR/env.sh"

P="$TELEMETRY_DATA/grafana/provisioning"
rm -rf "$P"
mkdir -p "$P/datasources" "$P/dashboards" "$P/alerting" "$TELEMETRY_DATA/grafana/plugins"

# Grafana datasource provisioning does not expand this shell variable itself,
# so the script substitutes the actual port before startup.
sed "s|\${POSTGRES_PORT}|$POSTGRES_PORT|g" \
  "$TELEMETRY_SRC/grafana/provisioning/datasources/timescale.yaml" > "$P/datasources/timescale.yaml"

# TELEMETRY_SRC points to the immutable Nix store copy,
# so Grafana reads dashboards directly from the packaged source tree.
sed "s|@DASH_PATH@|$TELEMETRY_SRC/grafana/dashboards|" \
  "$TELEMETRY_SRC/grafana/provisioning/dashboards/provider.yaml" > "$P/dashboards/provider.yaml"

# Alert-rule YAML files are copied when the source directory exists.
if [ -d "$TELEMETRY_SRC/grafana/provisioning/alerting" ]; then
  cp "$TELEMETRY_SRC/grafana/provisioning/alerting/"*.yaml "$P/alerting/" 2>/dev/null || true
fi

export GF_PATHS_DATA="$TELEMETRY_DATA/grafana"
export GF_PATHS_PLUGINS="$TELEMETRY_DATA/grafana/plugins"
export GF_PATHS_PROVISIONING="$P"
export GF_SERVER_HTTP_ADDR=0.0.0.0
export GF_SERVER_HTTP_PORT="$GRAFANA_PORT"
export GF_ANALYTICS_REPORTING_ENABLED=false
export GF_ANALYTICS_CHECK_FOR_UPDATES=false

# Enable View-only access for anonymous viewer
export GF_AUTH_ANONYMOUS_ENABLED=true
export GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer

exec grafana server --homepath "$GRAFANA_HOME"
