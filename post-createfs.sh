#!/bin/sh
# Post-createfs script for nerves_system_openwrt_one
#
# Inputs from Buildroot:
#   $1            BINARIES_DIR (also exported as env var)
#   BASE_DIR      Buildroot output dir
#   HOST_DIR      Buildroot host dir
#   NERVES_DEFCONFIG_DIR  this directory
#   BR2_EXTERNAL_NERVES_PATH  the nerves_system_br directory

set -e

FWUP_CONFIG="${NERVES_DEFCONFIG_DIR}/fwup.conf"

# Run the common nerves post-createfs (sets up env scripts, copies fwup.conf).
"${BR2_EXTERNAL_NERVES_PATH}/board/nerves-common/post-createfs.sh" \
    "${BINARIES_DIR}" "${FWUP_CONFIG}"

# Stage the snand-preloader.bin into BINARIES_DIR so the fwup.conf
# `mix burn` task can pick it up via ${NERVES_SYSTEM}/images/. fwup at
# firmware-build time only reliably sees the images dir, not the
# system source tree, so prebuilt blobs that need to ride along in
# the .fw must be copied into BINARIES_DIR here.
cp "${NERVES_DEFCONFIG_DIR}/prebuilt/openwrt-one-snand-preloader.bin" \
    "${BINARIES_DIR}/openwrt-one-snand-preloader.bin"

# --- Build the FIT image (kernel + DTB + cpio.gz initramfs) ---
# This is what U-Boot's `bootm` consumes after reading the "fit" UBI volume.

if [ -x "/usr/bin/mkimage" ]; then
    MKIMAGE="/usr/bin/mkimage"
elif [ -x "${HOST_DIR}/bin/mkimage" ]; then
    MKIMAGE="${HOST_DIR}/bin/mkimage"
else
    echo "ERROR: mkimage not found. Enable BR2_PACKAGE_HOST_UBOOT_TOOLS." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

cp "${BINARIES_DIR}/Image" "${WORK_DIR}/"
cp "${BINARIES_DIR}/mediatek/mt7981b-openwrt-one.dtb" "${WORK_DIR}/" 2>/dev/null \
    || cp "${BINARIES_DIR}/mt7981b-openwrt-one.dtb" "${WORK_DIR}/"
cp "${BINARIES_DIR}/rootfs.cpio.gz" "${WORK_DIR}/"
cp "${NERVES_DEFCONFIG_DIR}/openwrt-one.its" "${WORK_DIR}/"

(cd "${WORK_DIR}" && "${MKIMAGE}" -f openwrt-one.its \
    "${BINARIES_DIR}/openwrt-one-initramfs.itb")

echo "FIT image created: ${BINARIES_DIR}/openwrt-one-initramfs.itb"

# --- Build the UBI image for SPI NAND ---
# Layout: ubootenv + ubootenv2 + fip (prebuilt) + fit + rootfs_data
# NAND parameters: 128 KiB PEB, 2048 byte page (from MT7981B / Etron).

if [ -x "${HOST_DIR}/sbin/ubinize" ]; then
    UBINIZE="${HOST_DIR}/sbin/ubinize"
elif [ -x "${HOST_DIR}/bin/ubinize" ]; then
    UBINIZE="${HOST_DIR}/bin/ubinize"
else
    echo "WARNING: ubinize not found. UBI image NOT built." >&2
    echo "         Enable BR2_PACKAGE_HOST_MTD if you need it." >&2
    exit 0
fi

# Generate a placeholder ubootenv binary so ubinize doesn't fail. The system
# build doesn't know the application's metadata, so this just contains the
# OpenWrt U-Boot default env (from prebuilt/uboot-env-template.txt) plus a
# minimal nerves_fw_active=a entry. wrap-firmware.sh overwrites this with
# the real per-app env (template + meta.conf-derived nerves_fw_*) when it
# builds the flashable .ubi from a mix firmware .fw output.
#
# env_size 0x1F000 (= one UBI LEB) MUST match CONFIG_ENV_SIZE in the
# OpenWrt U-Boot loaded from our `fip` volume. With the full default env
# included, U-Boot's CRC check passes and it uses our env directly --
# bootcmd, boot_*, ubi_* and bootmenu_* all come straight from the
# template, so the device boots normally with no warnings.
if [ -x "${HOST_DIR}/bin/mkenvimage" ]; then
    cat "${NERVES_DEFCONFIG_DIR}/prebuilt/uboot-env-template.txt" \
        > "${BINARIES_DIR}/uboot-env.txt"
    printf 'nerves_fw_active=a\n' >> "${BINARIES_DIR}/uboot-env.txt"
    # -r for redundant env (we have two ubootenv volumes; the 5-byte
    # header is required for fw_printenv / UBootEnv to read it correctly).
    "${HOST_DIR}/bin/mkenvimage" -r -s 0x1F000 \
        -o "${BINARIES_DIR}/uboot-env.bin" \
        "${BINARIES_DIR}/uboot-env.txt"
    rm -f "${BINARIES_DIR}/uboot-env.txt"
else
    # Fall back to all-0xff (uninitialized) — U-Boot will see an invalid
    # CRC and rewrite with its compiled-in defaults on first boot.
    printf '\xff%.0s' $(seq 1 126976) > "${BINARIES_DIR}/uboot-env.bin"
fi

UBI_CFG="${BINARIES_DIR}/ubinize-fit.cfg"
sed -e "s|BOARD_DIR|${NERVES_DEFCONFIG_DIR}|g" \
    -e "s|BINARIES_DIR|${BINARIES_DIR}|g" \
    "${NERVES_DEFCONFIG_DIR}/ubinize-fit.cfg" > "${UBI_CFG}"

"${UBINIZE}" -p 128KiB -m 2048 \
    -o "${BINARIES_DIR}/openwrt-one-nand.ubi" "${UBI_CFG}"

rm -f "${UBI_CFG}"

UBI_SIZE=$(stat -c%s "${BINARIES_DIR}/openwrt-one-nand.ubi" 2>/dev/null \
    || stat -f%z "${BINARIES_DIR}/openwrt-one-nand.ubi")
echo "UBI image created: ${BINARIES_DIR}/openwrt-one-nand.ubi ($((UBI_SIZE / 1024)) KiB)"

cat <<EOF

=== nerves_system_openwrt_one build complete ===

Output images in ${BINARIES_DIR}:
  Image                       - kernel
  mt7981b-openwrt-one.dtb     - device tree
  rootfs.cpio.gz              - Nerves rootfs as cpio (used as initramfs)
  rootfs.squashfs             - Nerves rootfs as squashfs (Phase 2 use)
  openwrt-one-initramfs.itb   - FIT image for TFTP/UBI boot
  openwrt-one-nand.ubi        - Multi-volume UBI image for SPI NAND

To boot via TFTP (no NAND changes):
  tftpboot \$loadaddr openwrt-one-initramfs.itb && bootm

To install on a blank NAND (one-time, from U-Boot):
  tftpboot \$loadaddr openwrt-one-nand.ubi
  ubi detach
  mtd erase ubi
  mtd write spi-nand0 \$loadaddr 0x100000 \$filesize
  reset

EOF
