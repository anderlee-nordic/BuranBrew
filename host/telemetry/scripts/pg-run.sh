#!/usr/bin/env bash
# Starts the initialized PostgreSQL/TimescaleDB cluster on the configured port.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$SCRIPT_DIR/env.sh"
exec postgres -D "$TELEMETRY_DATA/pg" -c "port=$POSTGRES_PORT"
