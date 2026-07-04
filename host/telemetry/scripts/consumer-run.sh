#!/usr/bin/env bash
# Starts the Go telemetry archiver.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$SCRIPT_DIR/env.sh"
exec buranbrew-consumer
