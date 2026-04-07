# nerves_system_openwrt_one

Nerves system for the [OpenWRT One](https://openwrt.org/toh/openwrt/one) router
based on the MediaTek MT7981B (Filogic 820).

| Feature       | Description                                                |
| ------------- | ---------------------------------------------------------- |
| CPU           | 2x ARM Cortex-A53 @ 1.3 GHz                                |
| Memory        | 1 GB DDR4                                                  |
| Storage       | 128 MiB SPI NAND (Etron EM73C044SNB) + 4 MiB SPI NOR       |
| WiFi          | MT7976C dual-band WiFi 6                                   |
| Ethernet      | 2.5 GbE WAN (Airoha EN8811H) + 1 GbE LAN (internal PHY)    |
| Linux kernel  | 6.12 mainline + small patches                              |
| IEx terminal  | UART0 / serial console (115200 8N1)                        |
| GPIO, I2C, SPI| Yes - [Elixir Circuits](https://github.com/elixir-circuits)|
| RTC           | Yes (PCF8563 on I2C)                                       |
| Watchdog      | Yes (SoC + GPIO)                                           |

## Boot chain

```
BL2 (SPI NOR "bl2-nor")
  -> reads UBI volume "fip" from SPI NAND
  -> loads BL31 + U-Boot proper
U-Boot
  -> reads UBI volume "fit" (or fit_a/fit_b for A/B builds)
  -> bootm config-1 -> Linux + Nerves
```

The `fip` volume holds the OpenWrt-built ARM Trusted Firmware FIP. We don't
build it ourselves (it requires the MediaTek ATF fork) — see
`prebuilt/openwrt-one-fip.bin` and `prebuilt/README.md`.

## Initial install (one-time, blank board)

The very first install must be done from U-Boot because Linux isn't running
yet. After `mix firmware`, the build produces a `.ubi` file at
`./_build/${MIX_TARGET}_${MIX_ENV}/nerves/system/images/openwrt-one-nand.ubi`.

From the U-Boot serial console:

```
setenv ipaddr 192.168.X.Y
setenv serverip 192.168.X.Z
tftpboot $loadaddr openwrt-one-nand.ubi
ubi detach
mtd erase ubi
mtd write spi-nand0 $loadaddr 0x100000 $filesize
reset
```

After this the board autoboots Nerves on every power-on.

## Updates

Subsequent updates use `mix upload` and the standard Nerves OTA flow:

```sh
mix firmware
mix upload <ip-or-hostname>
```

The `.fw` file is uploaded over SSH and `fwup` writes the new fit image to
the inactive UBI volume, then flips the active slot via U-Boot env. If the
new firmware fails to boot, the bootloader rolls back automatically.

## Recovery

If you ever wipe the `ubi` partition without including a `fip` volume, BL2
cannot find U-Boot and the board hangs. Recovery: flip the **NAND/NOR boot
switch to NOR**, hold the **front panel button**, power on. You'll land in
the SPI NOR recovery U-Boot, from where you can TFTP-boot or re-flash NAND.

## Support

This is a custom Nerves system, not an official `nerves-project` system.
Patches and issues welcome.
