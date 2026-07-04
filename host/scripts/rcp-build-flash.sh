#!/usr/bin/env bash
# Run on the WORKSTATION (NCS v3.3.0 toolchain)
# Build and flash the the OpenThread Radio Co-Processor (RCP)
# firmware onto the nRF54L15 development kit.
set -euo pipefail

NCS_ROOT="${NCS_ROOT:-$HOME/ncs/v3.3.0}"
BOARD=nrf54l15dk/nrf54l15/cpuapp
BUILD_DIR=/tmp/buranbrew-rcp-build

cd "$NCS_ROOT"
west build -p always -d "$BUILD_DIR" -b "$BOARD" nrf/samples/openthread/coprocessor
west flash -d "$BUILD_DIR"

echo
echo "RCP flash finished. Plug the DK into the Pi"
