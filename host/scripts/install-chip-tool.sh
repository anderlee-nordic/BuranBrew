#!/usr/bin/env bash
# Fallback installer for chip-tool on an ARM64 Raspberry Pi if Nix is not available
set -euo pipefail
. "$(dirname "$0")/../host.env"

mkdir -p "$(dirname "$CHIP_TOOL")" "$CHIP_STORAGE"
URL="https://github.com/nrfconnect/sdk-connectedhomeip/releases/download/${NCS_TAG}/chip-tool_arm64"

echo "Fetching $URL"
if ! curl -fL -o "$CHIP_TOOL" "$URL"; then
  echo "Download failed. Open https://github.com/nrfconnect/sdk-connectedhomeip/releases"
  echo "find the ${NCS_TAG} release, and copy the chip-tool_arm64 asset URL manually." >&2
  exit 1
fi
chmod +x "$CHIP_TOOL"
"$CHIP_TOOL" --version || true
