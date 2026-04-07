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
