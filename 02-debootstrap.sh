#!/bin/bash
# ---------------------------------------------------------------------------
# STEP 2 — runs from the LIVE Linux. Mounts the new volumes and debootstraps
# a base Debian over the network, then preps for chroot.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "$0")/vars.sh"

command -v debootstrap >/dev/null || { echo "install debootstrap in the live env first"; exit 1; }

mkdir -p "$MNT"
mount "/dev/$VG/$LV_ROOT" "$MNT"
mkdir -p "$MNT/boot"
mount "$BOOT_PART" "$MNT/boot"
mkdir -p "$MNT/boot/efi"
mount "$ESP_PART" "$MNT/boot/efi"        # the EXISTING Asahi ESP (m1n1/U-Boot live here)

# --- network base install --------------------------------------------------
debootstrap --arch="$ARCH" \
  --include=locales,lvm2,cryptsetup,cryptsetup-initramfs,grub-efi-arm64,grub-efi-arm64-signed,initramfs-tools,sudo,netbase,ifupdown,iproute2,isc-dhcp-client,ca-certificates,console-setup,kbd \
  "$SUITE" "$MNT" "$MIRROR"

# --- carry config into the chroot -----------------------------------------
cp "$(dirname "$0")/vars.sh" "$MNT/root/vars.sh"
cp "$(dirname "$0")/03-chroot-setup.sh" "$MNT/root/03-chroot-setup.sh"
chmod +x "$MNT/root/03-chroot-setup.sh"

# --- bind mounts + enter ---------------------------------------------------
for fs in dev dev/pts proc sys run; do mount --rbind "/$fs" "$MNT/$fs"; done

echo "Base system installed. Now chroot and run the final setup:"
echo "  chroot $MNT /bin/bash"
echo "  /root/03-chroot-setup.sh"
