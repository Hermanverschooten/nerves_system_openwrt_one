#!/usr/bin/env bash
#
# wrap-firmware.sh — turn a Nerves `.fw` into a bootable OpenWRT One FIT image
#
# Background: a Nerves `.fw` file is a zip containing a squashfs rootfs (with
# the Erlang VM and your application's release inside). The OpenWRT One boot
# chain expects a U-Boot FIT image (`openwrt-one-initramfs.itb`) containing
# kernel + DTB + cpio.gz initramfs. This script bridges the two:
#
#   1. Extract  data/rootfs.img  (squashfs)         from the .fw
#   2. Extract  data/Image                          from the .fw
#   3. Extract  data/mt7981b-openwrt-one.dtb        from the .fw
#   4. unsquashfs the rootfs into a temp dir
#   5. Add the bits the kernel initramfs needs that the squashfs lacks:
#         - /init shell script that mounts devtmpfs and execs /sbin/init
#         - /dev/console char device node (5,1)
#   6. Repack as cpio.gz
#   7. mkimage everything into a FIT (.itb) using the system's openwrt-one.its
#
# Usage:
#   ./scripts/wrap-firmware.sh <input.fw> <output.itb>
#
# Requires (host): unzip, unsquashfs, cpio, gzip, mkimage, sudo (for mknod &
# preserving file ownership in the cpio).
#
# This is a Phase 2 development convenience script. Phase 3 will replace
# this with proper fwup.conf integration so `mix firmware` produces the
# .itb directly and `mix upload` can write to NAND via UBI volumes.

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <input.fw> <output.itb>" >&2
    exit 1
fi

FW_FILE="$1"
OUT_ITB="$2"

if [ ! -f "$FW_FILE" ]; then
    echo "ERROR: $FW_FILE does not exist" >&2
    exit 1
fi

# Locate this script's directory so we can find the .its template alongside it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ITS_TEMPLATE="${SYSTEM_DIR}/openwrt-one.its"

if [ ! -f "$ITS_TEMPLATE" ]; then
    echo "ERROR: ITS template not found at $ITS_TEMPLATE" >&2
    exit 1
fi

# Tool checks
for tool in unzip unsquashfs cpio gzip mkimage sudo; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool '$tool' not found in PATH" >&2
        exit 1
    fi
done

WORK="$(mktemp -d -t openwrt-one-wrap.XXXXXX)"
trap 'sudo rm -rf "$WORK"' EXIT

echo "==> Working in $WORK"

# 1-3: extract the three things we need from the .fw
echo "==> Extracting kernel, dtb, rootfs from $FW_FILE"
unzip -p "$FW_FILE" data/Image                    > "$WORK/Image"
unzip -p "$FW_FILE" data/mt7981b-openwrt-one.dtb  > "$WORK/mt7981b-openwrt-one.dtb"
unzip -p "$FW_FILE" data/rootfs.img               > "$WORK/rootfs.squashfs"

# 4: unsquashfs the rootfs (sudo to preserve owners/permissions)
echo "==> Unpacking squashfs..."
sudo unsquashfs -no-progress -d "$WORK/rootfs" "$WORK/rootfs.squashfs" > /dev/null

# 5: add the initramfs essentials. The squashfs is built without device nodes
#    or a top-level /init because Nerves normally mounts it as a real
#    block-device root, not as initramfs. For our boot path we need both.
echo "==> Adding initramfs essentials (/init, /dev/console)"

# /init script: mount devtmpfs (so /dev/console etc. exist before erlinit
# tries to use them) and exec the real init (erlinit at /sbin/init).
sudo tee "$WORK/rootfs/init" > /dev/null <<'EOF'
#!/bin/sh
# devtmpfs does not get automounted for initramfs
/bin/mount -t devtmpfs devtmpfs /dev

# use the /dev/console device node from devtmpfs if possible (avoids
# glibc ttyname_r confusion). Wrapped in a subshell so a failing exec
# doesn't terminate the parent.
if (exec 0</dev/console) 2>/dev/null; then
    exec 0</dev/console
    exec 1>/dev/console
    exec 2>/dev/console
fi

exec /sbin/init "$@"
EOF
sudo chmod +x "$WORK/rootfs/init"

# /dev/console — needed BEFORE devtmpfs is mounted for the redirect above.
sudo mkdir -p "$WORK/rootfs/dev"
sudo mknod -m 622 "$WORK/rootfs/dev/console" c 5 1

# 6: repack as cpio.gz (deterministic)
echo "==> Packing cpio.gz..."
( cd "$WORK/rootfs" && \
  sudo find . -mindepth 1 | LC_ALL=C sort | \
  sudo cpio --reproducible --quiet -o -H newc ) | gzip -9 > "$WORK/rootfs.cpio.gz"

CPIO_SIZE=$(stat -c%s "$WORK/rootfs.cpio.gz" 2>/dev/null || stat -f%z "$WORK/rootfs.cpio.gz")
echo "    rootfs.cpio.gz: $((CPIO_SIZE / 1024 / 1024)) MiB"

# 7: build the FIT image
echo "==> Building FIT image..."
cp "$ITS_TEMPLATE" "$WORK/openwrt-one.its"
( cd "$WORK" && mkimage -f openwrt-one.its "$OUT_ITB" >/dev/null )

OUT_SIZE=$(stat -c%s "$OUT_ITB" 2>/dev/null || stat -f%z "$OUT_ITB")
echo "==> Wrote $OUT_ITB ($((OUT_SIZE / 1024 / 1024)) MiB)"
echo ""
echo "To boot via TFTP from U-Boot:"
echo "  tftpboot \$loadaddr $(basename "$OUT_ITB")"
echo "  bootm"
