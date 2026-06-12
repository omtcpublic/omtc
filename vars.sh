# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Shared configuration for the Asahi UEFI -> Debian (debootstrap + LUKS) install
# Source this from the numbered scripts:  . ./vars.sh
# Everything here is run INSIDE a Linux environment on the Mac (live or chroot),
# NOT on macOS, except 00-macos-uefi-setup.sh.
# ---------------------------------------------------------------------------

# --- Target disk (verify under Linux with `lsblk`!) -------------------------
# Apple internal NVMe usually shows as nvme0n1 under the Asahi kernel.
export DISK="${DISK:-/dev/nvme0n1}"

# Partition node prefix (nvme uses pN, sd uses N). Auto-detected below.
case "$DISK" in
  *nvme*|*mmcblk*) export PART="${DISK}p" ;;
  *)              export PART="${DISK}"  ;;
esac

# --- Partition numbers ------------------------------------------------------
# The Asahi "UEFI environment only" install ALREADY created the ESP that the
# m1n1/U-Boot boot stub points at. DO NOT recreate it. Find its number with
# `lsblk -o NAME,PARTTYPENAME,SIZE` and set it here:
export ESP_PART="${ESP_PART:-${PART}5}"     # existing Asahi ESP (FAT) — REUSE, do not format if it has m1n1
export BOOT_PART="${BOOT_PART:-${PART}6}"   # NEW: /boot, unencrypted ext4
export LUKS_PART="${LUKS_PART:-${PART}7}"   # NEW: LUKS2 container (rest of free space)

# --- Names ------------------------------------------------------------------
export LUKS_NAME="cryptroot"     # /dev/mapper/cryptroot
export VG="debvg"                # LVM volume group
export LV_ROOT="root"
export LV_SWAP="swap"
export SWAP_SIZE="16G"           # tune to taste (you have 32 GB RAM)
# root LV takes the remaining VG space.

# --- Debian install ---------------------------------------------------------
export SUITE="trixie"            # Debian release to debootstrap
export MIRROR="http://deb.debian.org/debian"
export HOSTNAME_NEW="debian-asahi"
export ARCH="arm64"

# --- Asahi kernel source (Debian "Bananas" unofficial archive) --------------
# REQUIRED: stock Debian kernels DO NOT boot Apple Silicon. You must install the
# Asahi-patched kernel from the Bananas archive. The exact apt line + signing key
# + kernel package name move over time — get the CURRENT values from:
#   https://wiki.debian.org/InstallingDebianOn/Apple/M1
# Fill these in before running 03-chroot-setup.sh:
export BANANAS_APT_LINE="deb [signed-by=/usr/share/keyrings/bananas.gpg] https://bananas-archive.debian.net/bananas-archive ${SUITE}-bananas main"
export BANANAS_KEY_URL='https://bananas-archive.debian.net/bananas-archive/bananas-archive-keyring.asc'
export ASAHI_KERNEL_PKG='linux-image-asahi'

export MNT=/mnt/target
