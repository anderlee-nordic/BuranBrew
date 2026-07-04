#!/usr/bin/env bash
# Performs one-time native installation of OpenThread Border Router (OTBR) on the Pi
set -euo pipefail
. "$(dirname "$0")/../host.env"

sudo apt update
sudo apt install -y git lsb-release dbus avahi-daemon bluez
sudo systemctl enable --now dbus avahi-daemon

if [ ! -d "$HOME/ot-br-posix" ]; then
  git clone https://github.com/openthread/ot-br-posix "$HOME/ot-br-posix" --depth 1
fi
cd "$HOME/ot-br-posix"
git pull --unshallow || true    # no-op if already full
git checkout "$OTBR_REV"

./script/bootstrap

if [ ! -f /etc/iproute2/rt_tables ]; then
  sudo mkdir -p /etc/iproute2
  if [ -f /usr/share/iproute2/rt_tables ]; then
    sudo cp /usr/share/iproute2/rt_tables /etc/iproute2/rt_tables
  else
    sudo touch /etc/iproute2/rt_tables
  fi
fi

INFRA_IF_NAME="$INFRA_IF" ./script/setup    # builds + installs otbr-agent/otbr-web services

# Point otbr-agent at the RCP with the correct baud rate
sudo sed -i \
  "s|^OTBR_AGENT_OPTS=.*|OTBR_AGENT_OPTS=\"-I wpan0 -B $INFRA_IF spinel+hdlc+uart://$RCP_DEV?uart-baudrate=1000000\"|" \
  /etc/default/otbr-agent

sudo systemctl restart otbr-agent
sudo systemctl status otbr-agent --no-pager -l | head -15
echo
echo "OTBR installed successfully."
