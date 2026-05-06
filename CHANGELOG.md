# Changelog

## v0.2.3 (2026-05-06)

Routine upstream bump.

* `nerves_system_br` 1.33.4 → 1.33.7
  * Erlang/OTP 28.4.1 → 28.5
  * fwup 1.14.0 → 1.16.0
  * Buildroot 2025.11.2 → 2025.11.3

No system-side changes required.

## v0.2.2 (2026-04-09)

`mix burn` support via OpenWrt's NOR full-recovery mode.

* `mix burn` now prepares a FAT32 USB recovery stick that OpenWrt's
  SPI NOR recovery U-Boot can use to flash the entire SPI NAND —
  no serial console, no TFTP server, no typing of U-Boot commands.
  The stick contains the snand-preloader.bin (BL2) and our
  `openwrt-one-nand.ubi` (renamed to `factory.ubi`). See README.md
  "Initial install" for the full procedure.
* Ship `prebuilt/openwrt-one-snand-preloader.bin` from OpenWrt 24.10
  (same source + license as the FIP).
* `fwup.conf`: replace the erroring `complete` task with one that
  `mbr_write`s + `fat_mkfs`es + `fat_write`s the recovery files.
  The .fw file grows by ~33 MiB (the .ubi) + 234 KiB (preloader)
  but `mix burn` now Just Works with no per-app config.
* `post-createfs.sh`: stage the preloader into images/ so fwup can
  find it at firmware-build time.
* README: document USB stick recovery as the primary initial-install
  path; serial + TFTP demoted to "alternative".

## v0.2.1 (2026-04-08)

USB mass storage support.

* Linux: enable `CONFIG_SCSI`, `CONFIG_BLK_DEV_SD`, `CONFIG_USB_STORAGE`,
  `CONFIG_FAT_FS` + `CONFIG_VFAT_FS`, `CONFIG_EXFAT_FS`, and the
  matching NLS tables (`CP437`, `ISO8859-1`, `UTF-8`). USB sticks now
  enumerate as `/dev/sdN` and FAT/exFAT partitions mount and read.

## v0.2.0 (2026-04-08)

OTA + A/B slot support, kernel bump, several bug fixes that turned
session-1 workarounds into proper fixes.

### Added

* **A/B FIT slots:** UBI layout now uses `fit_a` (vol 3) and `fit_b`
  (vol 4) instead of a single `fit` volume. Each slot is sized at
  50 MiB. Active slot is selected at boot via
  `fit_${nerves_fw_active}` substitution in `ubi_read_production`.
* **Image-level boot fallback:** if `bootm` fails on the active slot,
  U-Boot's `boot_production` flips `nerves_fw_active`, `saveenv`s,
  and retries the other slot.
* **Bootcount-based runtime rollback:** OTA sets `upgrade_available=1`
  + `bootcount=0`; U-Boot's `nerves_count_attempt` script swaps slots
  once `bootcount > bootlimit` (default 3).
  `Nerves.Runtime.StartupGuard` clears the counters once the app is
  healthy.
* **`scripts/upload-ota.sh` + `scripts/apply-ota.exs`:** volume-level
  OTA via SFTP + `ubiupdatevol` + `fw_setenv`. Designed to be aliased
  as `mix upload` from the user app.
* **`NervesSystemOpenwrtOne.UBootEnvKVBackend`:** custom
  `Nerves.Runtime.KVBackend` that reads via the Erlang `UBootEnv`
  library and writes via the C `fw_setenv` (which issues
  `UBI_IOCVOLUP`). Without this the default backend returns `:eperm`
  on every `KV.put` and breaks `validate_firmware/0`.
* **Full OpenWrt 24.10 default U-Boot env baked into ubootenv volumes**
  via `prebuilt/uboot-env-template.txt`, with the `0x1F000` env size
  matching `CONFIG_ENV_SIZE` in OpenWrt's mt7981 U-Boot. Eliminates the
  cosmetic `boardid: U-boot environment CRC32 mismatch` warning that
  was caused by sizing our env smaller than what U-Boot writes back.
* `CONFIG_IP_ADVANCED_ROUTER=y`, `CONFIG_IP_MULTIPLE_TABLES=y`,
  `CONFIG_IP_ROUTE_MULTIPATH=y` so VintageNet's policy-routing setup
  doesn't crash with `RTNETLINK answers: Operation not supported`.

### Changed

* **Linux 6.12 → 6.18.12.**
* **SPI NAND driver path:** dropped the `spi-mtk-snfi` attempt and
  the Etron 0x77-shifted-manufacturer-ID workaround. Now uses
  `spi-mt65xx` with the OpenWrt SPI calibration patch stack
  (patches 121, 330, 431-435, 930) plus `mtk_bmt`. The chip is
  actually a Winbond 256 MiB part, not the 128 MiB Etron we initially
  guessed.
* **U-Boot env path in `fw_env.config`:** `/dev/ubi0_0` and
  `/dev/ubi0_1` instead of `/dev/ubi0:ubootenv`. The Erlang
  `uboot_env` library uses plain `File.open` and doesn't understand
  the `:volname` shorthand that fwup-tool's `fw_printenv` accepts.

### Fixed

* mkimage invocation in `wrap-firmware.sh` now prefers
  `/usr/bin/mkimage` over Buildroot's host build, because the latter
  ships with `MKIMAGE_DTC=""` and explodes with
  `sh: 1: -I: not found` whenever it tries to run dtc internally.

## v0.1.0 (2026-04-07)

Initial Nerves system for the OpenWRT One.

* Linux 6.12 mainline kernel with small patches
* Custom DTS based on mainline `mt7981b-openwrt-one.dts` with full
  peripheral enablement
* WiFi 2.4 / 5 GHz with proper calibration from factory partition
* Both Ethernet ports (1 GbE LAN + 2.5 GbE WAN with EN8811H PHY)
* RTC, GPIO watchdog, LEDs, buttons
* NAND boot via UBI volumes (fip + fit + ubootenv + rootfs_data)
* Pre-built FIP from official OpenWrt 24.10 release
