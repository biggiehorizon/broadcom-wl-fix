# Broadcom wl Driver Patch + Auto-Fallback

Fixes two kernel warnings in Broadcom's proprietary `wl` driver (broadcom-sta-dkms v6.30.223.271) for the **BCM43224** chipset found in 2012 MacBook Airs, with a boot-time auto-fallback in case the patches cause issues.

## The Warnings

| Warning | Cause | Fix |
|---|---|---|
| `UBSAN: array-index-out-of-bounds _wl_set_multicast_list` | `maclist->ea[1]` declared as size 1, used as size 32 | Use byte pointer arithmetic instead of array indexing |
| `WARNING: CPU: ... wl_inform_single_bss+0x268` | `beacon_proberesp->variable` is `u8[0]`, kernel fortify flags memcpy into it | Cast at call site to strip zero-size type info |

## Files

```
patches/
├── patch1-wl_linux.patch        # UBSAN fix (wl_linux.c)
└── patch2-wl_cfg80211.patch     # Fortify fix (wl_cfg80211_hybrid.c)
install.sh                       # Automated installer
wl-fallback.sh                   # Boot-time auto-revert script
wl-fallback.service              # systemd unit for fallback
README.md                        # This file
```

## Quick Install

```bash
git clone https://github.com/biggiehorizon/broadcom-wl-fix.git
cd broadcom-wl-fix
chmod +x install.sh
./install.sh
```

## Manual Install

```bash
# Install prerequisites
sudo apt install broadcom-sta-dkms

# Apply patches to DKMS source tree
sudo patch -d /usr/src/broadcom-sta-6.30.223.271 -p0 < patches/patch1-wl_linux.patch
sudo patch -d /usr/src/broadcom-sta-6.30.223.271 -p0 < patches/patch2-wl_cfg80211.patch

# Backup original module
cp /lib/modules/$(uname -r)/updates/dkms/wl.ko.zst /tmp/wl.ko.original.zst

# Rebuild and install
sudo dkms build broadcom-sta/6.30.223.271 --force
sudo dkms install broadcom-sta/6.30.223.271 --force

# Save fallback
sudo cp /tmp/wl.ko.original.zst /lib/modules/$(uname -r)/updates/dkms/wl.ko.fallback.zst

# Install fallback service
sudo cp wl-fallback.sh /usr/local/sbin/wl-fallback.sh
sudo chmod 755 /usr/local/sbin/wl-fallback.sh
sudo cp wl-fallback.service /etc/systemd/system/wl-fallback.service
sudo systemctl daemon-reload
sudo systemctl enable wl-fallback.service
```

## How the Fallback Works

1. On boot, `wl-fallback.service` runs `wl-fallback.sh`
2. Waits 30 seconds for WiFi interface (`wlp2s0`) to appear with carrier
3. If WiFi comes up: marks patched module as verified — subsequent boots skip the check
4. If WiFi doesn't come up: swaps in the original unpatched module and reloads

## Verify

```bash
sudo dmesg -c > /dev/null
sudo iw wlp2s0 scan > /dev/null 2>&1
sleep 8
dmesg | grep -E "WARNING|UBSAN" || echo "No warnings — patches working"
```