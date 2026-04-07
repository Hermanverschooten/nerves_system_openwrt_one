# Changelog

## v0.1.0 (2026-04-07)

Initial Nerves system for the OpenWRT One.

* Linux 6.12 mainline kernel with small patches
* Etron EM73C044SNB SPI NAND chip support patch
* mt76 mt7981-wmac clock failure handling fix
* Custom DTS based on mainline `mt7981b-openwrt-one.dts` with full
  peripheral enablement
* WiFi 2.4 / 5 GHz with proper calibration from factory partition
* Both Ethernet ports (1 GbE LAN + 2.5 GbE WAN with EN8811H PHY)
* RTC, GPIO watchdog, LEDs, buttons
* NAND boot via UBI volumes (fip + fit + ubootenv + rootfs_data)
* Pre-built FIP from official OpenWrt 24.10 release
