#!/usr/bin/env bash
# Form the Thread network and prints its active operational dataset
# Idempotent: if the node is already up, just prints state + dataset.
# NB: ot-ctl output is CRLF-terminated; strip \r before comparing anything.
set -euo pipefail

otq() { sudo ot-ctl "$@" | tr -d '\r'; }

STATE=$(otq state | head -1)
if [[ "$STATE" == "disabled" || "$STATE" == "detached" ]]; then
  otq dataset init new
  otq dataset commit active
  otq ifconfig up
  otq thread start
  # leader election
  for _ in $(seq 1 15); do
    sleep 2
    STATE=$(otq state | head -1)
    [[ "$STATE" == "leader" || "$STATE" == "router" ]] && break
  done
fi
echo "Thread state: $STATE   (expected: leader)"

echo
echo "Active Thread dataset (hex), write this down:"
otq dataset active -x | head -1
