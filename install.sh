#!/bin/bash
set -e

# broadcom-wl-fix installer
# Applies patches, builds module, installs fallback service

KERNEL_VER=$(uname -r)
SRC=/usr/src/broadcom-sta-6.30.223.271
WLDIR=/lib/modules/$KERNEL_VER/updates/dkms
PATCHDIR="$(dirname "$0")/patches"

echo "=== broadcom-wl-fix installer ==="
echo "Kernel: $KERNEL_VER"

# Guard: broadcom-sta-dkms must be installed first
if [ ! -d "$SRC" ]; then
    echo "ERROR: $SRC not found."
    echo "Install the driver first: sudo apt install broadcom-sta-dkms"
    exit 1
fi

# 1. Apply patches to DKMS source (idempotent — skip if already applied)
echo "[1/6] Applying patches..."
for patch in patch1-wl_linux.patch patch2-wl_cfg80211.patch; do
    if patch -d "$SRC" -p0 --dry-run --reverse --silent < "$PATCHDIR/$patch" 2>/dev/null; then
        echo "  $patch already applied — skipping"
    else
        sudo patch -d "$SRC" -p0 < "$PATCHDIR/$patch"
    fi
done

# 2. Backup original module
echo "[2/6] Backing up original module..."
cp "$WLDIR/wl.ko.zst" /tmp/wl.ko.original.zst

# 3. Rebuild
echo "[3/6] Rebuilding patched module..."
sudo dkms build broadcom-sta/6.30.223.271 --force

# 4. Install
echo "[4/6] Installing patched module..."
sudo dkms install broadcom-sta/6.30.223.271 --force

# 5. Save fallback and install scripts
echo "[5/6] Installing fallback system..."
sudo cp /tmp/wl.ko.original.zst "$WLDIR/wl.ko.fallback.zst"
sudo cp wl-fallback.sh /usr/local/sbin/wl-fallback.sh
sudo chmod 755 /usr/local/sbin/wl-fallback.sh
sudo cp wl-fallback.service /etc/systemd/system/wl-fallback.service
sudo systemctl daemon-reload
sudo systemctl enable wl-fallback.service

# 6. Load the patched module
echo "[6/6] Loading patched module..."
sudo modprobe -r wl 2>/dev/null || true
sleep 1
sudo modprobe wl
sleep 3

echo ""
echo "=== Done ==="
iwconfig wlp2s0 2>/dev/null || echo "Interface not yet up — reboot to confirm fallback service works"

echo ""
echo "Verify patches:"
echo "  sudo dmesg -c > /dev/null"
echo "  sudo iw wlp2s0 scan > /dev/null 2>&1"
echo "  sleep 8 && dmesg | grep -E 'WARNING|UBSAN' || echo 'clean'"
