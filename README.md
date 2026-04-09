# nerves_system_openwrt_one

[Nerves](https://nerves-project.org/) system for the
[OpenWRT One](https://openwrt.org/toh/openwrt/one) router based on the
MediaTek MT7981B (Filogic 820).

| Feature        | Description                                                |
| -------------- | ---------------------------------------------------------- |
| CPU            | 2x ARM Cortex-A53 @ 1.3 GHz                                |
| Memory         | 1 GB DDR4                                                  |
| Storage        | 256 MiB SPI NAND (Winbond) + 4 MiB SPI NOR                 |
| WiFi           | MT7976C dual-band WiFi 6                                   |
| Ethernet       | 2.5 GbE WAN (Airoha EN8811H) + 1 GbE LAN (internal PHY)    |
| Linux kernel   | 6.18 mainline + small patches (mtk_bmt + OpenWrt SPI cal)  |
| IEx terminal   | UART0 via front USB-C console port (115200 8N1, no adapter)|
| GPIO, I2C, SPI | Yes - [Elixir Circuits](https://github.com/elixir-circuits)|
| RTC            | Yes (PCF8563 on I2C)                                       |
| Watchdog       | Yes (SoC + GPIO)                                           |
| OTA updates    | Yes - A/B slot, automatic rollback on failure              |

## Boot chain

```
BL2 (SPI NOR "bl2-nor")
  -> reads UBI volume "fip" from SPI NAND
  -> loads BL31 + U-Boot proper
U-Boot
  -> reads UBI volume "fit_${nerves_fw_active}" (= fit_a or fit_b)
  -> bootm config-1 -> Linux + Nerves
```

The `fip` volume holds OpenWrt's pre-built ARM Trusted Firmware FIP. We
don't build it ourselves (it requires the MediaTek ATF fork) — see
`prebuilt/openwrt-one-fip.bin` and `prebuilt/README.md`.

## UBI layout on SPI NAND

```
vol_id  name        type     size    purpose
0       ubootenv    dynamic  128 KiB U-Boot env (redundant copy A)
1       ubootenv2   dynamic  128 KiB U-Boot env (redundant copy B)
2       fip         static   ~1 MiB  BL31 + U-Boot proper
3       fit_a       dynamic  50 MiB  kernel + initramfs, slot A
4       fit_b       dynamic  50 MiB  kernel + initramfs, slot B
5       rootfs_data dynamic  rest    OpenWrt-style data partition
```

The U-Boot environment baked into `ubootenv*` is the **full** OpenWrt
24.10 default env (`bootcmd`, `boot_*`, `ubi_*`, `bootmenu_*`) plus a
small Nerves overlay (`boot_active_slot`, `nerves_swap_active`,
`nerves_pre_boot`, `nerves_count_attempt`, `bootlimit`, slot-prefixed
`nerves_fw_*` metadata). See `prebuilt/uboot-env-template.txt`.

## Initial install (one-time, blank board)

The very first install uses the OpenWRT One's **NOR full-recovery
mode** — an independent U-Boot in SPI NOR that loads firmware from a
FAT-formatted USB stick and reflashes the entire SPI NAND. No serial
console, no TFTP server, no typing of U-Boot commands.

### Step 1: build the firmware and prepare a USB stick

```sh
MIX_TARGET=openwrt_one mix firmware
MIX_TARGET=openwrt_one mix burn
```

`mix burn` detects attached removable drives and prompts you to pick
one. It partitions the stick with a small FAT32 volume and writes two
files onto it:

- `openwrt-mediatek-filogic-openwrt_one-snand-preloader.bin` (BL2)
- `openwrt-mediatek-filogic-openwrt_one-factory.ubi` (our full
  multi-volume UBI image with fip + fit_a + fit_b + ubootenv + rootfs_data)

### Step 2: flash the device

1. Power down the OpenWRT One.
2. Plug the USB stick into the **Type-A** port (not Type-C).
3. Move the **boot switch to the NOR** position.
4. Hold the **front panel button** and apply power.
5. Release the button when all front-panel LEDs turn off.
6. Wait for the front LED to turn **green** (~30 seconds).
7. Move the boot switch back to **NAND**.
8. Power-cycle the device. It will autoboot Nerves.

### Alternative: serial + TFTP

The OpenWRT One has a built-in USB-to-serial converter on the front
USB-C port — just plug a USB-C cable, no external UART adapter needed
(`/dev/cu.usbmodem0001` on macOS, `/dev/ttyACM0` on Linux). If you
also have a TFTP server on the network, you can flash from the
U-Boot prompt (115200 8N1):

```
setenv ipaddr 192.168.X.Y
setenv serverip 192.168.X.Z
tftpboot $loadaddr openwrt-one-nand.ubi
ubi detach
mtd erase ubi
mtd write spi-nand0 $loadaddr 0x100000 $filesize
reset
```

## OTA updates

Use the standard `mix upload` flow. The user app should alias `upload`
to call this system's `scripts/upload-ota.sh`:

```elixir
# In your project's mix.exs
def project do
  [..., aliases: aliases()]
end

defp aliases do
  [upload: ["firmware", &upload_ota/1]]
end

defp upload_ota(args) do
  target = List.first(args) || "nerves.local"
  fw = Path.join([Mix.Project.build_path(), "nerves", "images", "#{@app}.fw"])
  script = Path.join([File.cwd!(), "..", "nerves_system_openwrt_one",
                      "scripts", "upload-ota.sh"])
  case System.cmd(script, [fw, "root@#{target}"], into: IO.stream()) do
    {_, 0} -> :ok
    {_, code} -> Mix.raise("upload-ota.sh exited with #{code}")
  end
end
```

Then:

```sh
MIX_TARGET=openwrt_one mix upload <ip-or-hostname>
```

What `upload-ota.sh` does:

1. Builds a FIT image (`.itb`) from the freshly-built `.fw` via
   `wrap-firmware.sh` (kernel + DTB + cpio.gz initramfs).
2. SFTPs the `.itb`, the slot-agnostic `nerves_fw_*` metadata, and a
   small Elixir apply script (`apply-ota.exs`) to the device.
3. On the device, runs `apply-ota.exs`, which:
   - reads the current `nerves_fw_active` (a or b),
   - writes the new `.itb` to the **inactive** slot's UBI volume via
     `ubiupdatevol /dev/ubi0_3` or `/dev/ubi0_4`,
   - patches `<inactive>.nerves_fw_*`, flips `nerves_fw_active`, and
     sets `upgrade_available=1` + `bootcount=0` via `fw_setenv`,
   - reboots.

The whole round trip (rebuild + SFTP + apply + reboot + heartbeat) is
typically ~30 seconds. No NAND wipe; the previous slot stays intact
for rollback.

### Why not stock fwup tasks?

`fwup`'s on-device actions (`raw_write`, `path_write`, `pipe_write`)
all use `pwrite()`, which UBI rejects with `EPERM` because the volume
needs `UBI_IOCVOLUP` to enter atomic-update mode first. The C tools
`ubiupdatevol` and `fw_setenv` issue that ioctl transparently for
`/dev/ubi*` paths; fwup doesn't.

## A/B slot rollback

The system supports two complementary kinds of rollback:

### Image-level (immediate)

If U-Boot's `ubi read` or `bootm` fails on the active slot (corrupt
FIT, empty volume, bad image header), the `boot_production` script
flips `nerves_fw_active`, runs `saveenv`, and retries with the other
slot. The demoted slot stays in env until the next OTA replaces it.

### Runtime-level (bootcount)

If the kernel boots cleanly but the application fails to come up
healthy, U-Boot uses the standard
[U-Boot bootcount convention](https://docs.u-boot.org/en/latest/usage/environment.html#bootcount-bootlimit-altbootcmd):

- OTA sets `upgrade_available=1` and `bootcount=0` along with the slot
  flip.
- On every boot while `upgrade_available=1`, U-Boot's
  `nerves_count_attempt` script bumps `bootcount`. Once it exceeds
  `bootlimit` (default 3), it swaps `nerves_fw_active`, resets the
  counters, and boots the previous slot.
- Once the new firmware is healthy,
  `Nerves.Runtime.StartupGuard` calls `Nerves.Runtime.validate_firmware/0`
  which clears `upgrade_available` + `bootcount` (via the system's
  `NervesSystemOpenwrtOne.UBootEnvKVBackend`), locking in the new slot.

To test the rollback path manually from a Nerves IEx shell:

```elixir
# Simulate "boot validated by app" never happening:
System.cmd("/usr/sbin/fw_setenv", ["upgrade_available", "1"])
System.cmd("/usr/sbin/fw_setenv", ["bootcount", "4"])  # bootlimit + 1
Nerves.Runtime.reboot()
# After reboot, you should be on the other slot.
```

## Runtime KV backend

Writing to a `/dev/ubi*` character device requires the
`UBI_IOCVOLUP` ioctl, so the default `Nerves.Runtime.KVBackend.UBootEnv`
(which uses the Erlang `uboot_env` library and plain `pwrite()`)
returns `{:error, :eperm}` from `Nerves.Runtime.KV.put/1`. That breaks
`Nerves.Runtime.validate_firmware/0` and the whole `StartupGuard`
chain.

This system ships its own backend at
`lib/nerves_system_openwrt_one/uboot_env_kv_backend.ex`:

- **Reads** delegate to `UBootEnv.read/0` (plain `pread()` works fine
  on UBI volumes).
- **Writes** shell out to the C `fw_setenv -s <file>` tool, which
  issues `UBI_IOCVOLUP` for `/dev/ubi*` paths.

User apps wire it up in `config/target.exs`:

```elixir
config :nerves_runtime,
  startup_guard_enabled: true,
  kv_backend: {NervesSystemOpenwrtOne.UBootEnvKVBackend, []}
```

And in `rel/vm.args.eex`:

```text
## Require StartupGuard's heart callback to register within 10 minutes,
## otherwise heart triggers a reboot and U-Boot bumps bootcount.
-env HEART_INIT_TIMEOUT 600
```

## Recovery

If you ever wipe the `ubi` partition without including a `fip` volume,
BL2 cannot find U-Boot and the board hangs. Recovery procedure:

1. Flip the **NAND/NOR boot switch to NOR**.
2. Hold the **front panel button** while powering on.
3. You'll land in the SPI NOR recovery U-Boot.
4. From there you can TFTP-boot the test FIT (`openwrt-one-initramfs.itb`)
   or re-flash the full UBI image (`openwrt-one-nand.ubi`).
5. Flip the boot switch back to NAND, power-cycle.

## Support

This is an unofficial Nerves system, not part of `nerves-project`.
Patches and issues welcome at
<https://github.com/Hermanverschooten/nerves_system_openwrt_one>.
