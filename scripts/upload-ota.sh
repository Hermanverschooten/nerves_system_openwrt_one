#!/usr/bin/env bash
#
# upload-ota.sh -- A/B-slot volume-level OTA for the OpenWRT One Nerves system.
#
# Reuses wrap-firmware.sh to turn a `mix firmware` .fw into a FIT image
# (.itb), uploads it via SFTP, and then writes it to the *inactive* fit
# UBI slot (fit_a or fit_b -> /dev/ubi0_3 or /dev/ubi0_4) with
# `ubiupdatevol`. Then it sets the new slot's nerves_fw_* metadata via
# `fw_setenv` and flips `nerves_fw_active` to point at the new slot.
# Finally it reboots, and U-Boot reads the new slot via the
# fit_${nerves_fw_active} substitution in ubi_read_production.
#
# Properties:
#   - no full NAND erase
#   - the previous slot remains untouched, so a manual rollback is just
#     `fw_setenv nerves_fw_active <other>` + reboot
#   - other UBI volumes (ubootenv*, fip, rootfs_data) are untouched
#
# Usage:
#   ./scripts/upload-ota.sh <input.fw> [user@host]
#
# Defaults:
#   user@host = root@nerves.local
#
# Examples:
#   ./scripts/upload-ota.sh _build/openwrt_one_dev/nerves/images/openwrt_one_test.fw
#   ./scripts/upload-ota.sh openwrt_one_test.fw root@192.168.17.77

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <input.fw> [user@host]" >&2
    exit 1
fi

FW_FILE="$1"
TARGET="${2:-root@nerves.local}"

if [ ! -f "$FW_FILE" ]; then
    echo "ERROR: $FW_FILE does not exist" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAP="${SCRIPT_DIR}/wrap-firmware.sh"

if [ ! -x "$WRAP" ]; then
    echo "ERROR: wrap-firmware.sh not found at $WRAP" >&2
    exit 1
fi

WORK="$(mktemp -d -t openwrt-one-ota.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

ITB="$WORK/openwrt_one_test.itb"

echo "==> Building FIT image from $FW_FILE"
"$WRAP" "$FW_FILE" "$ITB" >/dev/null

ITB_SIZE=$(stat -c%s "$ITB" 2>/dev/null || stat -f%z "$ITB")
echo "    .itb: $((ITB_SIZE / 1024 / 1024)) MiB"

# Build a SLOT-AGNOSTIC env file with bare nerves_fw_* keys (no a./b.
# prefix). The device-side script reads the current nerves_fw_active,
# computes the inactive slot, and prefixes each line on the fly. That
# way the host doesn't need to know which slot will be written to --
# the source of truth lives on the device.
META_TXT="$WORK/meta.txt"
unzip -p "$FW_FILE" meta.conf | awk '
    /^meta-/ {
        sub(/^meta-/, "")
        eq = index($0, "=")
        if (eq == 0) next
        key = substr($0, 1, eq - 1)
        val = substr($0, eq + 1)
        gsub(/^"|"$/, "", val)
        if (key == "product")           printf "nerves_fw_product=%s\n", val
        else if (key == "version")      printf "nerves_fw_version=%s\n", val
        else if (key == "platform")     printf "nerves_fw_platform=%s\n", val
        else if (key == "architecture") printf "nerves_fw_architecture=%s\n", val
        else if (key == "author")       printf "nerves_fw_author=%s\n", val
        else if (key == "description")  printf "nerves_fw_description=%s\n", val
        else if (key == "vcs-identifier") printf "nerves_fw_vcs_identifier=%s\n", val
        else if (key == "misc")         printf "nerves_fw_misc=%s\n", val
        else if (key == "uuid")         printf "nerves_fw_uuid=%s\n", val
    }
' > "$META_TXT"

echo "==> Will update env keys (slot prefix added on device):"
sed 's/^/      /' "$META_TXT"

REMOTE_ITB="/tmp/openwrt_one_ota.itb"
REMOTE_META="/tmp/openwrt_one_ota.env"
REMOTE_EXS="/tmp/openwrt_one_ota.exs"
APPLY_EXS="${SCRIPT_DIR}/apply-ota.exs"

if [ ! -f "$APPLY_EXS" ]; then
    echo "ERROR: apply-ota.exs not found at $APPLY_EXS" >&2
    exit 1
fi

echo "==> Uploading .itb, env keys and apply script to ${TARGET}"
sftp -o StrictHostKeyChecking=accept-new -b - "$TARGET" <<EOF
put $ITB $REMOTE_ITB
put $META_TXT $REMOTE_META
put $APPLY_EXS $REMOTE_EXS
bye
EOF

echo "==> Applying on device and rebooting"
# We upload an Elixir script (apply-ota.exs) instead of trying to cram
# the device-side logic into a single ssh-line snippet. Code.eval_file
# evaluates it inside the existing iex session, so it has the runtime
# tools (Nerves.Runtime, System, File, ...) available.
#
# Note on tooling: we use the C `fw_setenv` tool rather than the Erlang
# UBootEnv.write/1 because writing a UBI volume needs the UBI_IOCVOLUP
# ioctl to enter atomic-update mode -- plain pwrite() returns EPERM.
# The C tool issues IOCVOLUP transparently for /dev/ubi* paths; the
# Erlang library doesn't.
#
# The connection drops as soon as Nerves.Runtime.reboot() fires, which
# makes ssh exit non-zero -- that's expected, so we tolerate it.
ssh -o StrictHostKeyChecking=accept-new "$TARGET" "Code.eval_file(\"$REMOTE_EXS\")" || true

echo ""
echo "==> Update sent. Device is rebooting; should be back up in ~30s."
