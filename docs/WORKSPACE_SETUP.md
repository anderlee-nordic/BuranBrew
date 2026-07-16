# Workspace Setup (NCS v3.3.0)

This is a Zephyr workspace application. It lives inside the `BuranBrew` workspace
alongside the `nrf/`, `zephyr/`, and `bootloader/` repositories at the `v3.3.0`
workspace root.

```text
~/ncs/v3.3.0/                   <- NCS Zephyr workspace root
├─── .west/
│    └─── config
├─── zephyr/
├─── nrf/
├─── bootloader/
├─── modules/
│    └─── lib/matter/
└─── BuranBrew/                 <- This workspace checkout (West topdir)
     ├─── applications/
     ├─── docs/
     ├─── host/
     └─── tests/
```
The following steps are what worked at the time of writing this document. For
the most updated info, refer to
[nRF Connect Docs](https://nrfconnectdocs.nordicsemi.com/ncs/3.3.0/nrf/installation/install_ncs.html)

## 1. Install nrfutil components

```bash
nrfutil install sdk-manager
nrfutil install device
```

## 2. Install NCS v3.3.0 toolchain

```bash
nrfutil sdk-manager install v3.3.0
```

## 3. Enter the NCS toolchain shell

Use the shell entrypoint provided by sdk-manager for your installed toolchain.

```bash
nrfutil sdk-manager toolchain launch --ncs-version v3.3.0 --shell
```

## 4. Create NCS revision subdirectory
Creates the `v3.3.0` subdirectory and checks out the given revision of the nRF
Connect SDK inside it.

```bash
west init -m https://github.com/nrfconnect/sdk-nrf --mr v3.3.0 v3.3.0
```

Clone the project repositories

```bash
west update
```

Export a Zephyr CMake package.

```bash
west zephyr-export
```

## 5.  Clone repo into the workspace

```bash
git clone <repo-url> ~/ncs/v3.3.0/BuranBrew
```
