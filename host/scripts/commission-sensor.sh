#!/usr/bin/env bash
# Commission the amnin_sensors (node 1) over BLE and provisions it
# with the Thread operational dataset
#
#   scripts/commission-sensor.sh <DATASET_HEX>
#
# BLE connect on the Pi might fail, retrying 2-3 times is normal.
set -euo pipefail
. "$(dirname "$0")/../host.env"

mkdir -p "$CHIP_STORAGE"
CT() { "$CHIP_TOOL" "$@" --storage-directory "$CHIP_STORAGE"; }

DATASET=${1:?usage: commission-sensor.sh <DATASET_HEX>}

# test credential 20202021 / 3840
CT pairing ble-thread "$NODE_SENSOR" hex:"$DATASET" 20202021 3840
