#!/usr/bin/env bash
#
# Commission IKEA GRILLPLATS Matter-over-Thread plug.
#
#   ./commission-grillplats.sh <DATASET_HEX> <NODE_ID> <PAIRING_CODE|MT:payload>
#
# Factory-reset the plug right before running.
#
# The script handles:
#   - Stale SRP registrations.
#   - Attestation chain incompatibility.
#   - Premature BLE disconnect.
#   - Manual delivery of CommissioningComplete over Thread.
#   - Final verification.
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./host.env    # provides CHIP_TOOL and CHIP_STORAGE

DATASET=${1:?usage: $0 <DATASET_HEX> <NODE_ID> <PAIRING_CODE|MT:payload>}
NODE=${2:?missing NODE_ID}
CODE=${3:?missing PAIRING_CODE}

FAILSAFE_BUDGET=90                          # plug arms 94 s; keep 4 s margin
SERVICE=$(printf -- '-%016X' "$NODE")       # DNS-SD instance ends in -<node>
PAIR_LOG=$(mktemp /tmp/grillplats-pair.XXXXXX.log)
CC_LOG=${PAIR_LOG%.log}.cc.log

T0=$(date +%s)
log() { printf '[%4ds] %s\n' "$(( $(date +%s) - T0 ))" "$*"; }
die() { log "ERROR: $*"; exit 1; }

chiptool()   { "$CHIP_TOOL" "$@" --storage-directory "$CHIP_STORAGE"; }
plug_addrs() { avahi-browse -rpt _matter._tcp 2>/dev/null \
                 | awk -F';' -v s="$SERVICE" '/^=/ && $4 ~ s {print $8}' | sort -u; }
pair_log_has() { grep -Eq "$1" "$PAIR_LOG"; }

command -v avahi-browse >/dev/null \
  || die "avahi-browse not found (use the nix devShell or: apt install avahi-utils)"
mkdir -p "$CHIP_STORAGE"
# -------------------------------------------------------
# Flush stale SRP record left by a previous attempt
# -------------------------------------------------------
flush_stale_record() {
  local stale; stale=$(plug_addrs)
  [ -z "$stale" ] && return 0

  log "stale record for node $NODE found ($stale); flushing SRP server"
  log "note: this drops ALL records — power-cycle the sensor tag afterwards"
  command -v ot-ctl >/dev/null \
    || die "make sure ot-ctl is flused"

  ot-ctl srp server disable >/dev/null 2>&1
  sleep 1
  ot-ctl srp server enable  >/dev/null 2>&1
  for _ in $(seq 1 15); do [ -z "$(plug_addrs)" ] && return 0; sleep 1; done
  log "warning: stale record still cached in avahi; continuing anyway"
}
# -------------------------------------------------------
# BLE commissioning phase
# -------------------------------------------------------
run_ble_phase() {
  log "BLE commissioning started (log: $PAIR_LOG)"
  chiptool pairing code-thread "$NODE" hex:"$DATASET" "$CODE" \
    --bypass-attestation-verifier true >"$PAIR_LOG" 2>&1 &
  PAIR_PID=$!

  # Reaching ThreadNetworkEnable means the plug has received the Thread credentials
  # and is about to attempt network attachment.
  for _ in $(seq 1 120); do
    pair_log_has "Starting commissioning stage 'ThreadNetworkEnable'" && return 0
    kill -0 "$PAIR_PID" 2>/dev/null || break
    sleep 0.5
  done

  pair_log_has "commissioning completed (with|successfully)" && return 0
  die "BLE phase failed before ConnectNetwork: $PAIR_LOG"
}

# -------------------------------------------------------
# Wait for the BLE disconnect
# -------------------------------------------------------
wait_for_ble_drop() {
  DEADLINE=$(( $(date +%s) + FAILSAFE_BUDGET ))
  log "ConnectNetwork sent; fail-safe expires in ~${FAILSAFE_BUDGET}s"

  for _ in $(seq 1 10); do
    pair_log_has "BLE connection closed" && break
    pair_log_has "commissioning completed (with|successfully)" && return 0
    sleep 1
  done

  # The original chip-tool pairing process can no longer complete normally
  # kill manually
  kill "$PAIR_PID" 2>/dev/null; wait "$PAIR_PID" 2>/dev/null
  log "plug dropped BLE as expected; continuing over Thread"
}

# -------------------------------------------------------
# Wait for the plug on Thread
# -------------------------------------------------------
wait_for_plug_on_thread() {
  local addr
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    for addr in $(plug_addrs); do
      if ping -6 -c1 -W1 "$addr" >/dev/null 2>&1; then
        log "plug is live on Thread at $addr"
        return 0
      fi
    done
    sleep 2
  done
  log "plug never became pingable before the deadline, proceed to try anyway"
}

# -------------------------------------------------------
# Manually deliver the CommissioningComplete
# -------------------------------------------------------
send_commissioning_complete() {
  local attempt=0
  while [ "$(date +%s)" -lt $(( DEADLINE + 5 )) ]; do
    attempt=$(( attempt + 1 ))
    if chiptool generalcommissioning commissioning-complete "$NODE" 0 \
         --timeout 5 >"$CC_LOG" 2>&1 \
       && ! grep -q "Run command failure" "$CC_LOG"; then
      log "CommissioningComplete delivered (attempt #$attempt). Fabric committed"
      return 0
    fi
    log "  attempt #$attempt failed ($(grep -q 'Node ID resolved' "$CC_LOG" \
        && echo 'CASE unanswered' || echo 'not resolved'))"
  done
  die "CommissioningComplete never landed before fail-safe expiry: $PAIR_LOG $CC_LOG"
}

# -------------------------------------------------------
# Verify
# -------------------------------------------------------
verify() {
  sleep 2
  chiptool onoff read on-off "$NODE" 1 --timeout 10 >"$CC_LOG" 2>&1 \
    && ! grep -q "Run command failure" "$CC_LOG" \
    || die "commissioned, but operational read failed; see $CC_LOG"

  log "SUCCESS: node $NODE commissioned and answering over Thread"
  log "Suggest trying: chip-tool onoff toggle $NODE 1 --storage-directory $CHIP_STORAGE"
}

# ---------------------------------------------------------------------------
flush_stale_record
run_ble_phase
wait_for_ble_drop
wait_for_plug_on_thread
send_commissioning_complete
verify
