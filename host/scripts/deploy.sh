#!/usr/bin/env bash
# Copy the complete host/ runtime from the workstation to the Pi.
# Usage:
#   ./deploy.sh                      # default target
#   PI=<user>@<pi_addr> ./deploy.sh  # custom target
set -euo pipefail

PI="${PI:-root@10.0.0.4}"
DEST="${DEST:-~/buranbrew/host}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"   # the host/ runtime directory

ssh "$PI" "mkdir -p $DEST"

rsync -az --info=progress2 --delete \
  --exclude 'scripts/deploy.sh' \
  --exclude 'scripts/rcp-build-flash.sh' \
  --exclude 'result' \
  --exclude '__pycache__/' \
  --exclude '.git/' \
  --exclude '.direnv/' \
  "$SRC"/ "$PI:$DEST"/

echo "synced $SRC -> $PI:$DEST"
