# Host Bring-up & Commision Guide

BuranBrew employ a Raspberry Pi 4 as the Matter controller and OpenThread Border
Router for one sensor node and two actuator nodes.

The host flake provides the pinned `chip-tool`, Python control model, and
Cellarman telemetry stack. OTBR is installed natively because it configures
system services and the RCP.

[TOC]

## Static Data

`~/buranbrew/chip-storage` contains the Matter fabric keys. Back it up and
**DO NOT delete it** unless every device will be factory-reset and commissioned
again.

| Setting | Value |
|---|---|
| NCS and `chip-tool` release | `v3.3.0` |
| `ot-br-posix` revision | `fbde28a` |
| `amnin_sensors` tag | node `1` |
| Heating plug | node `11` |
| Cooling plug | node `12` |

When changing NCS, update `NCS_TAG` and `OTBR_REV` in `host.env`, together with
`ncsTag` and both `chipToolAssets` hashes in `flake.nix`. Keep the node IDs in
`host.env` synchronized with `models/config.yaml`.

## 1. One-time host setup

### Configure `host.env`

On the Pi, find the stable RCP path:

```bash
ls -l /dev/serial/by-id/
```

Set the Spinel VCOM and LAN interface:

```bash
RCP_DEV=/dev/serial/by-id/usb-SEGGER_J-Link_...-if02
INFRA_IF=eth0
```

Use the `if02` path, not `/dev/ttyACM*`, which may change after a reboot.

On DietPi systems with Docker bridges, restrict Avahi to the LAN interface in
`/etc/avahi/avahi-daemon.conf`:

```ini
[server]
allow-interfaces=eth0
```

```bash
sudo systemctl restart avahi-daemon
```

### Flash and deploy from the workstation

With the NCS v3.3.0 toolchain and J-Link available:

```bash
host/scripts/rcp-build-flash.sh
JLinkExe    # then: MSDDisable, SetHWFC Force, exit (one-time per DK)
host/scripts/deploy.sh
```

Move the nRF54L15 DK to the Pi after flashing. Override the deployment target
with `PI=<user>@<address>` and `DEST=<path>` when needed.

### Install and form OTBR on the Pi

```bash
cd ~/buranbrew/host
scripts/otbr-install.sh
scripts/otbr-form.sh
```

The first script installs the pinned OTBR revision and connects `otbr-agent` to
the RCP at 1M baud. The second forms the Thread network and prints its active
dataset hex. Save that dataset; every commissioning command needs it.

Re-running `otbr-form.sh` keeps an already active dataset.

## 2. Nix commands

Enter the host environment from the repository directory:

```bash
cd ~/buranbrew/host
nix develop
```

Inside this shell, `host.env` resolves `CHIP_TOOL` to the flake-pinned binary.
The flake supports both `aarch64-linux` and `x86_64-linux`.

| Command | Purpose |
|---|---|
| `nix develop` | Development and commissioning shell |
| `nix run .` | Run the fermentation control model |
| `nix run .#chip-tool -- ...` | Run a one-off Matter command |
| `nix run .#cellarman` | Start teh telemetry stack |
| `nix run .#cellarman-simulate` | Generate simulated telemetry |

Useful checks:

```bash
nix flake check
nix build .#chip-tool
nix build .#buranbrew-model
```

When Nix is unavailable on an ARM64 Pi, use
`scripts/install-chip-tool.sh` as the fallback installer.

## 3. Commission the sensor (node 1)

Run the following from `nix develop`. Before a fresh attempt, clear stale BLE
and SRP discovery state:

```bash
pkill -f chip-tool 2>/dev/null || true

for dev in $(bluetoothctl devices | awk '{print $2}'); do
  bluetoothctl remove "$dev"
done
sudo systemctl restart bluetooth
sleep 3

sudo ot-ctl srp server disable
sleep 1
sudo ot-ctl srp server enable
```

Restarting SRP removes discovery records, not Matter credentials. It drops all
current records, so power-cycle already commissioned devices afterward to make
them re-register immediately.

Power-cycle the tag, wait a few seconds, then commission it:

```bash
scripts/commission-sensor.sh <DATASET_HEX>
```

The tag uses setup passcode `20202021` and discriminator `3840`. The first BLE
connection may fail on the Pi; retrying the same command two or three times is
normal. Do not change the dataset or delete `chip-storage`.

Verify the endpoints (EP):

```bash
chip-tool temperaturemeasurement read measured-value 1 1 \
  --storage-directory "$HOME/buranbrew/chip-storage"

chip-tool temperaturemeasurement read measured-value 1 2 \
  --storage-directory "$HOME/buranbrew/chip-storage"

chip-tool relativehumiditymeasurement read measured-value 1 3 \
  --storage-directory "$HOME/buranbrew/chip-storage"
```

EP 1 is ambient temperature, EP 2 is internal temperature, and EP 3 is specific
gravity x1000. 

EP 2 and 3 may be null until a Tilt advertisement is received.

## 4. Commission the GRILLPLATS plugs (nodes 11 & 12)

Install the discovery utility used by the commissioning script if needed:

```bash
sudo apt install -y avahi-utils
```

Before commissioning, temporarily set the following in
`/etc/bluetooth/main.conf`:

```ini
[General]
Experimental = true
ControllerMode = le

[GATT]
ExchangeMTU = 48
```

Apply the settings:

```bash
sudo systemctl restart bluetooth
sudo systemctl is-active bluetooth
```

Factory-reset (long press until the red LED stops blinking) one plug
immediately before running its command. 

Run from `nix develop` (ONE node at a time):

```bash
scripts/commission-grillplats.sh <DATASET_HEX> 11 'MT:<HEAT_PAYLOAD>'
scripts/commission-grillplats.sh <DATASET_HEX> 12 'MT:<COOL_PAYLOAD>'
```

The script handles stale SRP records, the IKEA attestation-chain mismatch, the
premature BLE disconnect, delivery of `CommissioningComplete` over Thread, and
a final operational verification.

If the script flushes SRP, power-cycle the sensor tag afterward. Label the
physical plugs **HEAT/11** and **COOL/12**.

Verify both plugs:

```bash
chip-tool onoff toggle 11 1 \
  --storage-directory "$HOME/buranbrew/chip-storage"

chip-tool onoff toggle 12 1 \
  --storage-directory "$HOME/buranbrew/chip-storage"
```

After commissioning, remove `ExchangeMTU = 48`, restore the previous
`Experimental` and `ControllerMode` values, and restart Bluetooth. The temporary
settings are only for GRILLPLATS commissioning.

## 5. Run the host applications

Run the control model with the repository configuration:

```bash
cd ~/buranbrew/host
nix run . -- "$PWD/models/config.yaml"
```

For Cellarman operation, configuration, and dashboard usage, refer to the
[Cellarman Operation Guide](telemetry/README.md).

## Reflashing the sensor

A normal application-slot flash preserves the sensor's Matter settings, so node
1 remains commissioned. A full erase or device recovery removes the fabric and
requires commissioning again. Changing Matter endpoints alone does not require
a new commissioning cycle.
