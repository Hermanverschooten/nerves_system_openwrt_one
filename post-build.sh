#!/usr/bin/env bash
# Post-build script for nerves_system_openwrt_one

set -e

# Auto-load WiFi driver at boot.
# The mt798x-wmac platform device exposes a modalias of
# "of:NwifiT(null)Cmediatek,mt7981-wmac" which has a known mainline quirk
# (the literal "(null)" string for missing device_type) that prevents
# userspace modalias matching from auto-loading mt7915e. Force-loading
# via Buildroot's S11modules init script (which reads
# /etc/modules-load.d/*.conf) sidesteps the issue.
mkdir -p "${TARGET_DIR}/etc/modules-load.d"
echo "mt7915e" > "${TARGET_DIR}/etc/modules-load.d/mt7915e.conf"

# Create the fwup ops script for runtime firmware operations
# (factory-reset, revert, status, etc.)
mkdir -p "${TARGET_DIR}/usr/share/fwup"
"${HOST_DIR}/usr/bin/fwup" -c -f "${NERVES_DEFCONFIG_DIR}/fwup-ops.conf" \
    -o "${TARGET_DIR}/usr/share/fwup/ops.fw"
ln -sf ops.fw "${TARGET_DIR}/usr/share/fwup/revert.fw"

# Copy fwup_include to the binaries dir so the main fwup.conf can include
# its sub-configs (the Nerves common one + ours).
if [ -d "${NERVES_DEFCONFIG_DIR}/fwup_include" ]; then
    cp -rf "${NERVES_DEFCONFIG_DIR}/fwup_include" "${BINARIES_DIR}/"
fi
