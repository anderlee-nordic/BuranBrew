#!/usr/bin/env bash
# Creates the local TimescaleDB cluster on first run and applies
# PostgreSQL settings suitable for Pi. Existing clusters are left unchanged.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$SCRIPT_DIR/env.sh"
D="$TELEMETRY_DATA/pg"
if [ ! -s "$D/PG_VERSION" ]; then
  mkdir -p "$D"
  initdb -D "$D" -U buranbrew --auth=trust --encoding=UTF8
  cat >> "$D/postgresql.conf" << CONF
# --- BuranBrew PoC (2GB Pi tuning) ---
listen_addresses = '127.0.0.1'
port = $POSTGRES_PORT
unix_socket_directories = '$TELEMETRY_DATA'
shared_preload_libraries = 'timescaledb'
shared_buffers = 128MB
max_connections = 20
max_parallel_workers = 2
timescaledb.telemetry_level = off
CONF
  echo "initialised new cluster in $D"
else
  echo "cluster already exists in $D"
fi
