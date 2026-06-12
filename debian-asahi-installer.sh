#!/bin/bash
# ===========================================================================
#  debian-asahi-installer.sh
#  One-command guided Debian installer for Apple Silicon, run from a live
#  Asahi-kernel Linux AFTER you've installed the Asahi "UEFI environment only"
#  stub from macOS (see 00-macos-uefi-setup.sh).
#
#  Layout it produces (internal /boot, encrypted root):
#     [existing Asahi ESP]  m1n1/U-Boot/GRUB        (cleartext, reused)
#     /boot                 ext4                    (cleartext)
#     LUKS2 -> LVM(VG)      root + swap             (ENCRYPTED)
#
#  It does: validate stub -> partition free space -> LUKS2 -> LVM ->
#  debootstrap -> chroot config (kernel, crypttab, fstab, grub) -> done.
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=/tmp/debian-asahi-install.log
exec > >(tee -a "$LOG") 2>&1

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo -e "\n\033[1;36m==>\033[0m $*"; }
ask()  { local p="$1" d="${2:-}" v; if [ -n "$d" ]; then read -r -p "$p [$d]: " v; echo "${v:-$d}"; else read -r -p "$p: " v; echo "$v"; fi; }

# ---- preflight ------------------------------------------------------------
[ "$(uname -s)" = Linux ] || die "Run this from the live Asahi Linux env, not macOS. (Do 00-macos-uefi-setup.sh first.)"
[ "$(id -u)" = 0 ] || die "Run as root."
# shellcheck disable=SC1091
[ -f "$HERE/installer.conf" ] && . "$HERE/installer.conf"

: "${SUITE:=trixie}"; : "${MIRROR:=http://deb.debian.org/debian}"
: "${HOSTNAME_NEW:=debian-asahi}"; : "${VG:=debvg}"; : "${SWAP_SIZE:=16G}"
: "${TIMEZONE:=UTC}"; : "${LOCALE:=en_US.UTF-8}"; : "${ASSUME_YES:=0}"
: "${ASAHI_KERNEL_PKG:=linux-image-asahi}"; : "${ASAHI_FW_PKGS:=}"
LUKS_NAME=cryptroot; LV_ROOT=root; LV_SWAP=swap; MNT=/mnt/target

for t in sgdisk cryptsetup pvcreate vgcreate lvcreate mkfs.ext4 mkfs.vfat debootstrap blkid lsblk partprobe; do
  command -v "$t" >/dev/null || MISSING+=" $t"
done
if [ -n "${MISSING:-}" ]; then
  info "Missing tools:$MISSING"
  if command -v apt-get >/dev/null; then
    read -r -p "Install them in the live env via apt? [y/N] " a
    [ "$a" = y ] && apt-get update && apt-get install -y gdisk cryptsetup-bin lvm2 dosfstools debootstrap util-linux || die "install the missing tools and re-run"
  else die "install:$MISSING"; fi
fi

# ---- kernel-source sanity (the #1 way to end up with an unbootable box) ---
if [ -z "${BANANAS_APT_LINE:-}" ] || [ -z "${BANANAS_KEY_URL:-}" ]; then
  cat <<EOF

\033[1;33mWARNING:\033[0m BANANAS_APT_LINE / BANANAS_KEY_URL are not set in installer.conf.
Stock Debian kernels CANNOT boot Apple Silicon — you need the Asahi-patched
kernel from the Debian "Bananas" archive. Get the current apt line + key from:
  https://wiki.debian.org/InstallingDebianOn/Apple/M1
Without it the install completes but WILL NOT BOOT.
EOF
  read -r -p "Continue anyway (not recommended)? [y/N] " a; [ "$a" = y ] || exit 1
fi

# ---- disk detection -------------------------------------------------------
if [ -z "${DISK:-}" ]; then
  DISK=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}' | grep -E 'nvme0n1$' | head -1) || true
  [ -z "$DISK" ] && DISK=$(ask "Target disk (e.g. /dev/nvme0n1)")
fi
[ -b "$DISK" ] || die "$DISK is not a block device"
case "$DISK" in *nvme*|*mmcblk*) P="${DISK}p";; *) P="$DISK";; esac

# ---- locate + validate the existing Asahi ESP (must contain m1n1) ---------
info "Looking for the Asahi UEFI stub (m1n1) on $DISK ..."
ESP_PART=""
while read -r dev fstype; do
  [ "$fstype" = vfat ] || continue
  tmp=$(mktemp -d)
  if mount -o ro "/dev/$dev" "$tmp" 2>/dev/null; then
    if [ -e "$tmp/m1n1.bin" ] || [ -d "$tmp/m1n1" ]; then ESP_PART="/dev/$dev"; fi
    umount "$tmp"
  fi
  rmdir "$tmp"
  [ -n "$ESP_PART" ] && break
done < <(lsblk -rno NAME,FSTYPE "$DISK" | awk 'NF==2{print $1, $2}')

[ -n "$ESP_PART" ] || die "No Asahi ESP with m1n1 found on $DISK.
Either the 'UEFI environment only' step wasn't run, or the ESP was clobbered
(e.g. reformatted in Disk Utility). Re-run the Asahi installer first."
info "Found Asahi ESP: $ESP_PART (will be REUSED, not reformatted)"

# ---- collect answers ------------------------------------------------------
[ -z "${USERNAME:-}" ] && USERNAME=$(ask "New username")
[ -n "$USERNAME" ] || die "username required"

read -r -s -p "LUKS disk-encryption passphrase: " LUKS_PASS; echo
read -r -s -p "Repeat passphrase: " LUKS_PASS2; echo
[ "$LUKS_PASS" = "$LUKS_PASS2" ] || die "passphrases do not match"
[ -n "$LUKS_PASS" ] || die "empty passphrase"

read -r -s -p "Password for user '$USERNAME': " USER_PASS; echo
read -r -s -p "Repeat: " USER_PASS2; echo
[ "$USER_PASS" = "$USER_PASS2" ] || die "passwords do not match"

# ---- plan + confirm -------------------------------------------------------
cat <<EOF

------------------------------------------------------------------
 Install plan
   Disk:           $DISK
   Reuse ESP:      $ESP_PART   (Asahi m1n1/U-Boot — untouched)
   New /boot:      ${P}<next>  ext4, 1 GiB, cleartext
   New LUKS2:      ${P}<next>  -> LVM '$VG' (root + ${SWAP_SIZE} swap), ENCRYPTED
   Debian:         $SUITE  (mirror $MIRROR)
   Host / user:    $HOSTNAME_NEW / $USERNAME
   Kernel:         $ASAHI_KERNEL_PKG (Bananas archive)
 macOS is NOT touched. New partitions go into free space after the ESP.
------------------------------------------------------------------
EOF
if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Type ERASE to create the new partitions and install: " c
  [ "$c" = ERASE ] || die "aborted"
fi

# ---- cleanup trap ---------------------------------------------------------
cleanup() {
  set +e
  umount -R "$MNT" 2>/dev/null
  cryptsetup close "$LUKS_NAME" 2>/dev/null
}
trap cleanup EXIT

# ---- partition free space -------------------------------------------------
info "Creating /boot and LUKS partitions in free space..."
sgdisk "$DISK" \
  -n 0:0:+1G -t 0:8300 -c 0:debian-boot \
  -n 0:0:0   -t 0:8300 -c 0:debian-luks
partprobe "$DISK"; sleep 2

# the two partitions we just added = the last two on the disk
mapfile -t PARTS < <(lsblk -rno NAME "$DISK" | tail -n +2)
BOOT_PART="/dev/${PARTS[-2]}"
LUKS_PART="/dev/${PARTS[-1]}"
info "/boot=$BOOT_PART  luks=$LUKS_PART"

mkfs.ext4 -q -L deb-boot "$BOOT_PART"

# ---- LUKS2 (passphrase via stdin, no second prompt) -----------------------
info "Formatting LUKS2 container..."
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode "$LUKS_PART" --key-file=-
printf '%s' "$LUKS_PASS" | cryptsetup open "$LUKS_PART" "$LUKS_NAME" --key-file=-

# ---- LVM ------------------------------------------------------------------
pvcreate -ff -y "/dev/mapper/$LUKS_NAME"
vgcreate "$VG" "/dev/mapper/$LUKS_NAME"
lvcreate -y -L "$SWAP_SIZE" -n "$LV_SWAP" "$VG"
lvcreate -y -l 100%FREE     -n "$LV_ROOT" "$VG"
mkfs.ext4 -q -L deb-root "/dev/$VG/$LV_ROOT"
mkswap    -L deb-swap "/dev/$VG/$LV_SWAP"

# ---- mount + debootstrap --------------------------------------------------
info "Mounting and debootstrapping Debian $SUITE (network)..."
mkdir -p "$MNT"
mount "/dev/$VG/$LV_ROOT" "$MNT"
mkdir -p "$MNT/boot"; mount "$BOOT_PART" "$MNT/boot"
mkdir -p "$MNT/boot/efi"; mount "$ESP_PART" "$MNT/boot/efi"

debootstrap --arch=arm64 \
  --include=locales,lvm2,cryptsetup,cryptsetup-initramfs,initramfs-tools,grub-efi-arm64,grub-efi-arm64-signed,sudo,netbase,ifupdown,iproute2,isc-dhcp-client,ca-certificates,console-setup,kbd,network-manager,openssh-client,curl,gpg \
  "$SUITE" "$MNT" "$MIRROR"

# ---- write the chroot phase (vars baked in) -------------------------------
info "Configuring the installed system (chroot phase)..."
LUKS_UUID=$(blkid -s UUID -o value "$LUKS_PART")
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
ESP_UUID=$(blkid  -s UUID -o value "$ESP_PART")

cat >"$MNT/root/chroot-phase.sh" <<CHROOT
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# apt sources
cat >/etc/apt/sources.list <<EOF
deb $MIRROR $SUITE main contrib non-free-firmware
deb $MIRROR ${SUITE}-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free-firmware
EOF

# Bananas archive (Asahi-patched kernel). Key, repo line, and pin priority.
if [ -n "${BANANAS_KEY_URL:-}" ]; then
  curl -fsSL "${BANANAS_KEY_URL}" | gpg --dearmor -o /usr/share/keyrings/bananas.gpg
  echo "${BANANAS_APT_LINE}" >/etc/apt/sources.list.d/bananas.list
  cat >/etc/apt/preferences.d/bananas.pref <<EOF
Package: *
Pin: release n=${SUITE}-bananas
Pin-Priority: 1050
EOF
fi
apt-get update

# locale / timezone / host
echo "$HOSTNAME_NEW" >/etc/hostname
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
sed -i "s/^# *${LOCALE}/${LOCALE}/" /etc/locale.gen && locale-gen
update-locale LANG=$LOCALE

# crypttab — initramfs unlocks cryptroot at boot
echo "$LUKS_NAME UUID=$LUKS_UUID none luks,initramfs" >/etc/crypttab

# fstab
cat >/etc/fstab <<EOF
/dev/$VG/$LV_ROOT  /          ext4  defaults,noatime  0 1
UUID=$BOOT_UUID    /boot      ext4  defaults          0 2
UUID=$ESP_UUID     /boot/efi  vfat  umask=0077        0 1
/dev/$VG/$LV_SWAP  none       swap  sw                0 0
EOF

# users (secrets arrive via env, never written into this script)
echo "root:\$USER_PASS" | chpasswd          # set root = same as user pw; change later
useradd -m -s /bin/bash -G sudo "\$USERNAME"
echo "\$USERNAME:\$USER_PASS" | chpasswd

# Asahi kernel + firmware tooling (REQUIRED to boot)
apt-get install -y $ASAHI_KERNEL_PKG $ASAHI_FW_PKGS || {
  echo "!! Asahi kernel install failed — check the Bananas repo in installer.conf"; exit 7; }
# Extract Apple Silicon firmware (WiFi/BT/etc.) from the ESP if tooling present
command -v asahi-fwextract >/dev/null && asahi-fwextract /boot/efi/vendorfw /lib/firmware || true

# initramfs with cryptsetup (so the LUKS prompt appears at boot)
echo "CRYPTSETUP=y" >/etc/cryptsetup-initramfs/conf-hook
update-initramfs -u -k all

# GRUB onto the existing Asahi ESP; --removable writes \EFI\BOOT\BOOTAA64.EFI
sed -i 's/^#\?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=n/' /etc/default/grub
grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=debian --removable --recheck
update-grub

systemctl enable NetworkManager ssh 2>/dev/null || true
CHROOT
chmod +x "$MNT/root/chroot-phase.sh"

# ---- enter chroot automatically ------------------------------------------
for fs in dev dev/pts proc sys run; do mount --rbind "/$fs" "$MNT/$fs"; done
cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
chroot "$MNT" /usr/bin/env USERNAME="$USERNAME" USER_PASS="$USER_PASS" \
  /bin/bash /root/chroot-phase.sh
rm -f "$MNT/root/chroot-phase.sh"

# ---- done -----------------------------------------------------------------
info "Install complete. Log: $LOG"
cat <<EOF

Next:
  reboot
At the power-button boot picker, pick the UEFI/Debian entry. Early in boot you
will be asked for the LUKS passphrase (if the screen looks idle, just start
typing — the first prompt can be hidden under boot messages).

After first login: change the root password (it was set equal to your user's).
EOF
# trap cleanup runs on normal exit too (unmounts + closes luks)
