# BUILD_STEPS

This page describes the build and flash steps of `amnin_sensors` firmware for
the nRF54L15 tag.

## Context

`amnin_sensors` is based on the upstream NCS Matter Template sample
(`nrf/samples/matter/template/`), then was customized for the BME680 ambient
sensor plus a Tilt hydrometer read over a BLE observer. See
[WORKSPACE SETUP](../../docs/WORKSPACE_SETUP.md) for how to prepare the NCS workspace.

## Prerequisites

- NCS `v3.3.0` workspace prepared per `WORKSPACE_SETUP.md`.
- This repo's `amnin_sensors/` reproduced at
  `~/ncs/v3.3.0/BuranBrew/applications/amnin_sensors` as a Zephyr workspace
  application.
- nRF54L15 TAG board connected via its J-Link probe.
- Toolchain environment active (so `west`, `nrfutil`, and the Matter west
  commands are on `PATH`).

All commands below run from the application directory:

```
cd ~/ncs/v3.3.0/BuranBrew/applications/amnin_sensors
```

## Data model

The tag exposes four endpoints. EP0 is the Matter root; the rest are the
application:

| Endpoint | Device type              | Cluster                      | Carries                                 |
|----------|--------------------------|------------------------------|-----------------------------------------|
| EP1      | Temperature Sensor 0x0302 | TemperatureMeasurement      | BME680 ambient temperature (C) |
| EP2      | Temperature Sensor 0x0302 | TemperatureMeasurement      | Tilt brew temperature (C)      |
| EP3      | Humidity Sensor 0x0307    | RelativeHumidityMeasurement | Tilt specific gravity, as SG x1000      |

Note on EP3: Matter has no standard "specific gravity" cluster. EP3 reuses the
standard RelativeHumidityMeasurement cluster for convineience.

## 1. Regenerate ZAP outputs

The `.zap` file defines which clusters/attributes/endpoints exist. Editing it
(e.g., adding new endpoints) requires regenerating the C++ data-model sources
under `src/default_zap/zap-generated/` before building.

Edit the data model with the ZAP GUI:

```
west zap-gui
```

(Edit and then save, close GUI.)

Regenerate the C++ sources:

```
west zap-generate
```

Verify the generated endpoint count matches the four endpoints above:

```
grep FIXED_ENDPOINT_COUNT src/default_zap/zap-generated/endpoint_config.h
```

Expected: `FIXED_ENDPOINT_COUNT (4)`.

### If ZAP tool download fails (TLS / certificate error)

Update certifi and point Python HTTPS clients to its CA bundle:
```bash
python -m pip install --upgrade certifi
export SSL_CERT_FILE="$(python -m certifi)"
export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
```

## 2. Build

```
west build -b nrf54l15tag/nrf54l15/cpuapp -p
```

The tag is a sleepy device by design. Sleepy behavior comes from Kconfig
defaults (Thread MTD + Matter ICD).

```
grep -E 'CONFIG_PM=|CONFIG_OPENTHREAD_MTD=|CONFIG_CHIP_ENABLE_ICD_SUPPORT=' \
  build/amnin_sensors/zephyr/.config
```

Expected:

- `CONFIG_PM=y`
- `CONFIG_OPENTHREAD_MTD=y`
- `CONFIG_CHIP_ENABLE_ICD_SUPPORT=y`

## 3. Flash

The nRF54L15 protects the MCUboot region in RRAM at every boot, so a normal
`west flash` (which programs `merged.hex` from address 0x0) fails with
`Address 0x00000000 is in a protected RRAMC region`. As the result, there are
two flashing options.

### Flash the application only, keep commissioning

Programs just the signed app slot so it preserves the fabric and factory data.
No re-commissioning needed:

```
west flash --hex-file build/amnin_sensors/zephyr/zephyr.signed.hex
```

`nrfutil` alternative: program only the signed app slot with no erase, then
pin-reset.

```
nrfutil device program \
  --firmware build/amnin_sensors/zephyr/zephyr.signed.hex \
  --options chip_erase_mode=ERASE_NONE \
  --serial-number <SN>
nrfutil device reset --reset-kind RESET_PIN --serial-number <SN>
```

N.B. Adding or changing a Matter endpoint is a firmware/data-model change only,
it does not require re-pairing the device to the fabric.

### Full reflash

Needed when MCUboot, the partition layout, or the factory data
changes. This does a full chip erase (ERASEALL), which wipes the fabric and
factory data, so the device must be re-commissioned afterward:

```
west flash --erase
```

## 4. Logs over RTT

```
west rtt --no-rebuild
```

Because of sleep, RTT output pauses between wakeups. Sensor
report lines appear on the reporting cadence.
