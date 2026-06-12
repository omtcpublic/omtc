#!/bin/bash
# ---------------------------------------------------------------------------
# STEP 0 — runs on macOS (Terminal). Sets up the m1n1 -> U-Boot -> UEFI stub.
#
# This launches the OFFICIAL Asahi installer. The installer is interactive and
# does its own APFS resize + partitioning; we cannot fully script its prompts,
# so follow the on-screen choices below.
# ---------------------------------------------------------------------------
set -euo pipefail

cat <<'EOF'
================================================================================
 Asahi UEFI environment install (macOS side)
================================================================================
Before you start:
  • Back up (Time Machine). This resizes a live APFS container.
  • Plug in power. Have an external USB-C keyboard handy as a fallback.

When the installer runs, choose:
  1) "Install an OS"  ->  "UEFI environment only (m1n1 + U-Boot + ESP)"
  2) Give it the size you want to carve out of macOS for ALL of Debian
     (the ESP is tiny; the rest becomes free space we partition in step 1).
       - You have ~995 GB free, ~25 GB used by macOS.
  3) Let it finish, then follow its instructions to reboot by HOLDING the
     power button -> Options -> select the new "UEFI boot" entry.
  4) At the U-Boot/UEFI screen you now have a generic ARM UEFI machine.

Then boot a live Linux that supports Apple Silicon (Asahi-kernel live USB) to
run steps 1-3 of this repo. You CANNOT debootstrap from macOS.
================================================================================
EOF

read -r -p "Launch the official Asahi installer now? [y/N] " ok
[ "$ok" = y ] || { echo "Aborted. Re-run when ready."; exit 0; }

# The canonical entry point. Points at Asahi's prod installer_data.json, which
# contains the "UEFI environment only" entry we want.
curl https://alx.sh | sh
