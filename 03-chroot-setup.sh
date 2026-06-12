#!/bin/bash
# ---------------------------------------------------------------------------
# STEP 3 — runs INSIDE the chroot. Installs the Asahi kernel, wires up LUKS
# unlock at boot (crypttab + initramfs), and installs GRUB to the Asahi ESP.
# ---------------------------------------------------------------------------
set -euo pipefail
. /root/vars.sh

# --- apt sources -----------------------------------------------------------
cat >/etc/apt/sources.list <<EOF
deb $MIRROR $SUITE main contrib non-free-firmware
deb $MIRROR ${SUITE}-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free-firmware
EOF

# --- Bananas archive (REQUIRED: Asahi-patched kernel + firmware) -----------
# Stock Debian kernels cannot drive Apple Silicon. Fill BANANAS_* in vars.sh
# from https://wiki.debian.org/InstallingDebianOn/Apple/M1 before running.
if [ -n "$BANANAS_KEY_URL" ]; then
  apt-get update && apt-get install -y curl gpg
  curl -fsSL "$BANANAS_KEY_URL" | gpg --dearmor -o /usr/share/keyrings/bananas.gpg
  echo "$BANANAS_APT_LINE" >/etc/apt/sources.list.d/bananas.list
else
  echo "!! BANANAS_KEY_URL unset — set up the Asahi kernel archive per the wiki !!"
fi
apt-get update

# --- locale / host / root pw ----------------------------------------------
echo "$HOSTNAME_NEW" >/etc/hostname
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen
echo ">> Set root password:"; passwd

# --- discover UUIDs --------------------------------------------------------
LUKS_UUID=$(blkid -s UUID -o value "$LUKS_PART")
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
ESP_UUID=$(blkid  -s UUID -o value "$ESP_PART")

# --- crypttab: unlock cryptroot at boot from the initramfs -----------------
cat >/etc/crypttab <<EOF
$LUKS_NAME UUID=$LUKS_UUID none luks,initramfs
EOF

# --- fstab -----------------------------------------------------------------
cat >/etc/fstab <<EOF
/dev/$VG/$LV_ROOT  /          ext4  defaults,noatime  0 1
UUID=$BOOT_UUID    /boot      ext4  defaults          0 2
UUID=$ESP_UUID     /boot/efi  vfat  umask=0077        0 1
/dev/$VG/$LV_SWAP  none       swap  sw                0 0
EOF

# --- Asahi kernel + firmware ----------------------------------------------
# The internal keyboard at the LUKS prompt needs the Apple HID + dwc3 modules
# in the initramfs. MODULES=most (default) usually covers it; force-list if not.
apt-get install -y "$ASAHI_KERNEL_PKG" || {
  echo "!! Asahi kernel install failed — check the Bananas repo config !!"; exit 1; }

# Apple Silicon firmware is extracted from macOS and lives on the ESP; ensure
# the asahi firmware tooling / /lib/firmware is populated per the wiki.
# (asahi-installer copied firmware into the ESP with copy_firmware:true.)

# --- LUKS in initramfs -----------------------------------------------------
echo "CRYPTSETUP=y" >/etc/cryptsetup-initramfs/conf-hook
update-initramfs -u -k all

# --- GRUB onto the existing Asahi ESP -------------------------------------
# U-Boot (from the Asahi stub) hands off to GRUB here. --removable also writes
# the fallback \EFI\BOOT\BOOTAA64.EFI path that U-Boot looks for.
sed -i 's/^#\?GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="rd.luks.name='"$LUKS_UUID"'='"$LUKS_NAME"'"/' /etc/default/grub
sed -i 's/^#\?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=n/' /etc/default/grub  # /boot is clear
grub-install --target=arm64-efi --efi-directory=/boot/efi \
             --bootloader-id=debian --removable --recheck
update-grub

cat <<EOF

Done. Exit the chroot, unmount, and reboot:
  exit
  umount -R $MNT
  cryptsetup close $LUKS_NAME   # (after unmount)
  reboot
At the power-button boot picker choose the UEFI/Debian entry. You'll be asked
for the LUKS passphrase early in boot (if the screen looks hung, start typing).
EOF
