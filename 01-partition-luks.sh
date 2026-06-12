#!/bin/bash
# ---------------------------------------------------------------------------
# STEP 1 — runs from a LIVE Linux (Asahi-kernel) booted via the UEFI stub.
# Creates: /boot (clear ext4) + LUKS2 -> LVM (root + swap). Reuses the existing
# Asahi ESP — it is NOT touched here.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/vars.sh"

echo "Target disk: $DISK"
echo "  ESP  (reuse, untouched): $ESP_PART"
echo "  /boot (new ext4):        $BOOT_PART"
echo "  LUKS  (new):             $LUKS_PART"
lsblk -o NAME,SIZE,PARTTYPENAME,FSTYPE,MOUNTPOINT "$DISK" || true
echo
echo "This will CREATE new partitions in the free space after the ESP and"
echo "ERASE anything currently in $BOOT_PART and $LUKS_PART."
read -r -p "Type ERASE to continue: " c; [ "$c" = ERASE ] || { echo abort; exit 1; }

# --- Create the two new partitions in free space ---------------------------
# We use sgdisk against the FREE space. Adjust start/size if your free region
# differs; `sgdisk -p $DISK` shows the current table and free sectors.
#   /boot = 1 GiB ext4 (Linux filesystem, type 8300)
#   LUKS  = rest of disk             (Linux filesystem, type 8300)
sgdisk "$DISK" \
  -n 0:0:+1G   -t 0:8300 -c 0:debian-boot \
  -n 0:0:0     -t 0:8300 -c 0:debian-luks
partprobe "$DISK"; sleep 1
lsblk -o NAME,SIZE,PARTTYPENAME "$DISK"

# --- /boot (cleartext — required; GRUB+kernel live here) -------------------
mkfs.ext4 -L deb-boot "$BOOT_PART"

# --- LUKS2 container -------------------------------------------------------
# LUKS2 is fine for ROOT because the Asahi-kernel initramfs unlocks it.
# (Only GRUB-unlocked /boot would force LUKS1/PBKDF2 — we keep /boot clear.)
echo ">> Set your disk-encryption passphrase:"
cryptsetup luksFormat --type luks2 "$LUKS_PART"
echo ">> Re-enter it to open the container:"
cryptsetup open "$LUKS_PART" "$LUKS_NAME"

# --- LVM: VG with root + swap ----------------------------------------------
pvcreate "/dev/mapper/$LUKS_NAME"
vgcreate "$VG" "/dev/mapper/$LUKS_NAME"
lvcreate -L "$SWAP_SIZE" -n "$LV_SWAP" "$VG"
lvcreate -l 100%FREE     -n "$LV_ROOT" "$VG"

mkfs.ext4 -L deb-root "/dev/$VG/$LV_ROOT"
mkswap  -L deb-swap "/dev/$VG/$LV_SWAP"

echo "Partitioning + LUKS + LVM done. Next: ./02-debootstrap.sh"
