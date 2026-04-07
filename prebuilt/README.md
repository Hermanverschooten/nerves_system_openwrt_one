# Prebuilt blobs for OpenWRT One NAND boot

## openwrt-one-fip.bin

ARM Trusted Firmware FIP (Firmware Image Package) containing BL31 and
the OpenWrt-built U-Boot proper for the OpenWRT One. Loaded by BL2
(in SPI NOR `bl2-nor` partition) from the `fip` UBI volume on SPI NAND.

This is a pre-built binary blob extracted from the official OpenWrt
release because it's signed/built with the MediaTek ATF fork which is
not in mainline TF-A and we deliberately don't build it ourselves.

**Source**: `openwrt-24.10.0-mediatek-filogic-openwrt_one-factory.ubi`,
volume name `fip`, downloaded from
<https://downloads.openwrt.org/releases/24.10.0/targets/mediatek/filogic/>

**To extract from a fresh factory.ubi**:

```sh
pip install --user ubi_reader
ubireader_extract_images -o /tmp/extract \
    openwrt-24.10.0-mediatek-filogic-openwrt_one-factory.ubi
cp /tmp/extract/*/img-*_vol-fip.ubifs openwrt-one-fip.bin
```

The first 4 bytes should be `01 00 64 aa` (ToC magic `0xaa640001` LE)
to confirm it's a valid FIP container.

**Why we ship this**: BL2 in `bl2-nor` looks for a UBI volume named
`fip` on SPI NAND to load BL33 (U-Boot proper). Without it, BL2 fails
and the board can only boot via the SPI NOR recovery path (front
button hold + NAND/NOR switch). Including the official fip in our
NAND image keeps the production autoboot path working.
