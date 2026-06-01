# Broadcom wl Driver Patch + Auto-Fallback

Fixes two known kernel warnings in the proprietary Broadcom `wl` driver (broadcom-sta-dkms v6.30.223.271) for the **BCM43224** chipset found in 2012 MacBook Airs, and provides a boot-time auto-fallback system.

## Background

The BCM43224 WiFi chip in the 2012 MacBook Air is **not supported by any open-source Linux driver** (`brcmsmac`, `b43`, etc.). The only option is Broadcom's proprietary `wl` module from the `broadcom-sta-dkms` package. This driver has two known bugs on modern kernels that produce kernel warnings:

1. **UBSAN array-index-out-of-bounds** in `_wl_set_multicast_list` — writing multicast addresses into a struct with `ea[1]` triggers the kernel's UBSAN on any index > 0
2. **Fortified memcpy false-positive** in `wl_inform_single_bss` — a zero-length array (`u8 variable[0]`) in a packed struct causes the kernel's FORTIFY_SOURCE to emit a runtime WARNING even though the caller validates the size

These warnings don't crash the system by themselves, but on a memory-constrained machine they contribute to instability when combined with other memory pressure.

## The Patches

Both patches are minimal one-liner `sed` commands against the DKMS source tree at `/usr/src/broadcom-sta-6.30.223.271/`:

### Patch 1: UBSAN out-of-bounds fix

**File:** `src/wl/sys/wl_linux.c` line 1939

The original code indexes into `maclist->ea[i]` where `ea` is declared `struct ether_addr ea[1]`. The kernel's UBSAN correctly flags any index > 1 as out-of-bounds, even though the allocation covers `MAXMULTILIST` (32) entries. Fix by using byte pointer arithmetic instead of array indexing.

```bash
sudo sed -i 's/bcopy(ha->addr, \&maclist->ea\[i++\], ETHER_ADDR_LEN);/bcopy(ha->addr, ((u8 *)maclist->ea) + (i++ * ETHER_ADDR_LEN), ETHER_ADDR_LEN);/' /usr/src/broadcom-sta-6.30.223.271/src/wl/sys/wl_linux.c
```

### Patch 2: Fortified memcpy false-positive fix

**File:** `src/wl/sys/wl_cfg80211_hybrid.c` line 2030

`beacon_proberesp->variable` is declared `u8 variable[0]` (zero-length array). When passed to `memcpy` inside `wl_cp_ie()`, the kernel's fortify sees destination size 0 and fires a WARNING. The fix casts at the call site to strip the zero-size type info from the pointer.

```bash
sudo sed -i 's/wl_cp_ie(wl, beacon_proberesp->variable,/wl_cp_ie(wl, (u8 *)beacon_proberesp->variable,/' /usr/src/broadcom-sta-6.30.223.271/src/wl/sys/wl_cfg80211_hybrid.c
```

## Auto-Fallback System

### How it works

1. The patched `wl.ko` is installed as the default module
2. On boot, `wl-fallback.service` runs `wl-fallback.sh`
3. The script waits up to **30 seconds** for the WiFi interface (`wlp2s0`) to appear with carrier
4. If WiFi comes up: the patched module is marked as "verified working" — subsequent boots skip the 30s wait
5. If WiFi does NOT come up within 30s: the script swaps in the original unpatched module and reloads the driver

### Files

| File | Purpose |
|---|---|
| `/usr/local/sbin/wl-fallback.sh` | Fallback detection script |
| `/etc/systemd/system/wl-fallback.service` | systemd unit (runs before network.target) |
| `/lib/modules/.../wl.ko.fallback.zst` | Original unpatched module (backup) |
| `/lib/modules/.../wl.ko.working.zst` | Marker — patched module verified in a previous boot |

## Installation

### 1. Install prerequisites

```bash
sudo apt install broadcom-sta-dkms
```

### 2. Apply patches to source

```bash
sudo sed -i 's/bcopy(ha->addr, \&maclist->ea\[i++\], ETHER_ADDR_LEN);/bcopy(ha->addr, ((u8 *)maclist->ea) + (i++ * ETHER_ADDR_LEN), ETHER_ADDR_LEN);/' /usr/src/broadcom-sta-6.30.223.271/src/wl/sys/wl_linux.c

sudo sed -i 's/wl_cp_ie(wl, beacon_proberesp->variable,/wl_cp_ie(wl, (u8 *)beacon_proberesp->variable,/' /usr/src/broadcom-sta-6.30.223.271/src/wl/sys/wl_cfg80211_hybrid.c
```

### 3. Backup original module

```bash
cp /lib/modules/$(uname -r)/updates/dkms/wl.ko.zst /tmp/wl.ko.original.zst
```

### 4. Rebuild and install patched module

```bash
sudo dkms build broadcom-sta/6.30.223.271 --force
sudo dkms install broadcom-sta/6.30.223.271 --force
```

### 5. Preserve fallback

```bash
sudo cp /tmp/wl.ko.original.zst /lib/modules/$(uname -r)/updates/dkms/wl.ko.fallback.zst
```

### 6. Install fallback service

```bash
sudo cp wl-fallback.sh /usr/local/sbin/wl-fallback.sh
sudo chmod 755 /usr/local/sbin/wl-fallback.sh
sudo cp wl-fallback.service /etc/systemd/system/wl-fallback.service
sudo systemctl daemon-reload
sudo systemctl enable wl-fallback.service
```

### 7. Reload the module to test

```bash
sudo modprobe -r wl && sleep 2 && sudo modprobe wl && sleep 5
iwconfig wlp2s0
```

### 8. Verify patches are working

```bash
# Clear dmesg and trigger a scan
sudo dmesg -c > /dev/null
sudo iw wlp2s0 scan > /dev/null 2>&1
sleep 8

# Should show NO WARNING, UBSAN, or memcpy messages related to wl
dmesg | grep -E "wl_inform_single_bss|_wl_set_multicast_list|WARNING|UBSAN" | grep wl || echo "No warnings — patches working"
```

## Verification

| Before Patch | After Patch |
|---|---|
| `WARNING: CPU: ... wl_inform_single_bss+0x268` on every scan | No warnings |
| `UBSAN: array-index-out-of-bounds ... _wl_set_multicast_list` on network changes | No warnings |
| `memcpy: detected field-spanning write (size 430)` | No warnings |

## License

MIT — share freely, patch your own hardware.