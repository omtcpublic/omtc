# asahi-debian-netinstall

Clean, network-installed Debian on an Apple Silicon Mac (tested target: M2 Max),
booted through the Asahi **UEFI environment** stub, with **LUKS2 + LVM** full-disk
encryption on root. macOS is kept intact.

## Why it's shaped this way

Apple Silicon has no BIOS/UEFI you can point an ISO at. The Asahi installer
(run from macOS) sets up the boot chain:

```
Apple iBoot → m1n1 (stage 1) → m1n1 (stage 2: DT + U-Boot) → U-Boot/UEFI → GRUB → kernel
```

You pick **"UEFI environment only"** so you end up with a generic ARM UEFI
machine. Then you boot a live Linux, partition the free space, debootstrap
Debian over the network, install the **Asahi-patched kernel**, and point GRUB at
the existing Asahi ESP.

**The kernel is the catch:** stock Debian arm64 kernels can't drive Apple's NVMe,
keyboard, or display. You must install the Asahi kernel from the Debian **Bananas**
archive — see <https://wiki.debian.org/InstallingDebianOn/Apple/M1> and fill the
`BANANAS_*` values in `vars.sh`.

## FDE reality on Apple Silicon
- Encrypted **root** (LUKS2→LVM), unlocked by passphrase from the initramfs. ✅
- **ESP and `/boot` stay in the clear** — required; there is no Secure/Measured Boot.
- **No TPM/Secure-Enclave auto-unlock** — you type the passphrase every boot.
- Internal keyboard works at the prompt if the Apple HID modules are in the
  initramfs (default `MODULES=most` covers it); keep a USB-C keyboard as fallback.
- First decrypt prompt can be buried under boot logs — start typing if it "hangs".

## One-liner install (Asahi-style)

Host this folder somewhere static (a GitHub repo's raw URLs, a gist, or your own
server), point `BASE_URL` in `bootstrap.sh` at it, then run the **same command on
both phases** — it detects macOS vs Linux automatically:

```sh
curl -fsSL https://YOURHOST/bootstrap.sh | sh
```

- **Run #1, on macOS** → installs the Asahi UEFI stub, then tells you to reboot.
- Reboot (hold power → pick the UEFI entry) into a **live Asahi-kernel Linux**.
- **Run #2, on Linux** → downloads + runs the full LUKS/debootstrap installer.

Pass config as env vars on the line (they override `installer.conf`):

```sh
curl -fsSL https://YOURHOST/bootstrap.sh | \
  BANANAS_KEY_URL=... BANANAS_APT_LINE='deb ... trixie main' DISK=/dev/nvme0n1 sh
```

> **Why two runs, not one?** Unlike Asahi (which lays down a prebuilt image from
> macOS), this builds Debian on the real hardware, so the heavy half must run from
> a live Linux after a reboot. That reboot is unavoidable — so the "one-liner" is
> one URL invoked once per phase.

## Install — the one-command path (recommended, if running locally)

Mirrors the Asahi installer's single guided flow.

1. **macOS:** `./00-macos-uefi-setup.sh` → choose **UEFI environment only**, give it
   the size for all of Debian, reboot into the new UEFI entry.
2. **Boot a live Asahi-kernel Linux**, copy this folder onto it.
3. **Edit `installer.conf`** — fill the `BANANAS_*` Asahi-kernel source (required;
   from the wiki) and any defaults you want. Leave blanks to be asked.
4. Run the guided installer:
   ```
   sudo ./debian-asahi-installer.sh
   ```
   It auto-detects the NVMe, **validates the Asahi m1n1 stub on the ESP** (refuses to
   run if the ESP was clobbered in Disk Utility), prompts for passphrase + user, then
   does partition → LUKS2 → LVM → debootstrap → kernel → GRUB and finishes. Reboot
   into Debian; you'll be asked for the LUKS passphrase early in boot.

   Secrets (passphrase, user password) are prompted, passed via env to the chroot,
   and never written to disk. Log at `/tmp/debian-asahi-install.log`.

## Manual / reference path (the same steps, broken out)
Edit `vars.sh` first (`DISK`, partition numbers via `lsblk`, `BANANAS_*`), then:

| # | Where | Script |
|---|-------|--------|
| 0 | macOS Terminal | `00-macos-uefi-setup.sh` → **UEFI environment only** |
| 1 | live Linux | `sudo ./01-partition-luks.sh` |
| 2 | live Linux | `sudo ./02-debootstrap.sh` |
| 3 | inside chroot | `/root/03-chroot-setup.sh` |

## Status / honesty
This is a working scaffold, not a turnkey installer. The parts that depend on the
current Bananas archive (apt line, signing key, kernel package name) are marked
with placeholders because they change over time. Verify partition numbers and the
firmware step against the wiki before running on real hardware.
