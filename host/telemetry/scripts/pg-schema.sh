#!/usr/bin/env bash
# Waits for PostgreSQL, creates the buranbrew database when needed, and applies
# the TimescaleDB schema.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$SCRIPT_DIR/env.sh"
PSQL=(psql -h 127.0.0.1 -p "$POSTGRES_PORT" -U buranbrew -v ON_ERROR_STOP=1)
for _ in {1..60}; do
  pg_isready -h 127.0.0.1 -p "$POSTGRES_PORT" -U buranbrew >/dev/null 2>&1 && break
  sleep 1
done
"${PSQL[@]}" -d postgres -tAc "select 1 from pg_database where datname='buranbrew'" | grep -q 1 \
  || createdb -h 127.0.0.1 -p "$POSTGRES_PORT" -U buranbrew buranbrew
"${PSQL[@]}" -d buranbrew -f "$TELEMETRY_SRC/sql/schema.sql"
