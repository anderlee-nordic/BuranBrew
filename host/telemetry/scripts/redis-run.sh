#!/usr/bin/env bash
# Runs a local, persistent Redis instance used as the bounded telemetry buffer.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$SCRIPT_DIR/env.sh"
mkdir -p "$TELEMETRY_DATA/redis"
exec redis-server \
  --port "$REDIS_PORT" --bind 127.0.0.1 \
  --dir "$TELEMETRY_DATA/redis" \
  --appendonly yes --save "" \
  --maxmemory 64mb --maxmemory-policy noeviction
