#!/bin/bash
# wl-fallback.sh — Auto-fallback for patched broadcom-sta wl driver
# If the patched wl.ko doesn't bring up WiFi within 30s of boot,
# swaps in the original module and reloads it.
#
# Installed to /usr/local/sbin/wl-fallback.sh
# Paired with wl-fallback.service

set -e

WIFI_IFACE="wlp2s0"
TIMEOUT=30
PATROLLED_MODULE="/lib/modules/$(uname -r)/updates/dkms/wl.ko.zst"
FALLBACK_MODULE="/lib/modules/$(uname -r)/updates/dkms/wl.ko.fallback.zst"
WORKING_MODULE="/lib/modules/$(uname -r)/updates/dkms/wl.ko.working.zst"

# If there's already a "known working" module saved, no need to test again
if [ -f "$WORKING_MODULE" ]; then
    logger -t wl-fallback "Patched module already verified working in a previous boot. Skipping fallback check."
    exit 0
fi

logger -t wl-fallback "Starting WiFi driver health check (timeout: ${TIMEOUT}s)..."

# Wait for the interface to appear and get carrier
for ((i=0; i<TIMEOUT; i++)); do
    if ip link show "$WIFI_IFACE" >/dev/null 2>&1; then
        STATE=$(cat /sys/class/net/"$WIFI_IFACE"/carrier 2>/dev/null || echo 0)
        if [ "$STATE" = "1" ]; then
            logger -t wl-fallback "WiFi interface $WIFI_IFACE is UP with carrier. Patched module OK."
            # Mark this module as working for future boots
            cp "$PATROLLED_MODULE" "$WORKING_MODULE"
            exit 0
        fi
        logger -t wl-fallback "Interface $WIFI_IFACE present but no carrier yet (${i}s)..."
    else
        logger -t wl-fallback "Interface $WIFI_IFACE not yet present (${i}s)..."
    fi
    sleep 1
done

# If we get here, the patched module failed. Fall back to original.
logger -t wl-fallback "TIMEOUT — WiFi did not come up within ${TIMEOUT}s. Falling back to original module."

# Guard: ensure fallback module exists before destroying the patched one
if [ ! -f "$FALLBACK_MODULE" ]; then
    logger -t wl-fallback "CRITICAL: $FALLBACK_MODULE not found — cannot revert. Was step 5 of installation skipped?"
    exit 1
fi

# Unload the patched module
modprobe -r wl 2>/dev/null || true
sleep 1

# Save a copy of the failed patched module before overwriting (recovery aid)
cp "$PATROLLED_MODULE" "${PATROLLED_MODULE}.failed.zst" 2>/dev/null || true

# Swap in the fallback
cp "$FALLBACK_MODULE" "$PATROLLED_MODULE"
depmod -a || true

# Reload
modprobe wl || true
sleep 3

# Verify
if ip link show "$WIFI_IFACE" >/dev/null 2>&1; then
    logger -t wl-fallback "Fallback module loaded successfully — $WIFI_IFACE is present."
else
    logger -t wl-fallback "CRITICAL: Fallback module also failed to bring up $WIFI_IFACE."
fi

exit 0
