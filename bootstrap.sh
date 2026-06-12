#!/bin/sh
# ===========================================================================
#  bootstrap.sh — the one-liner entry point (POSIX sh, pipe-safe).
#
#  Run the SAME command on both phases; it detects where you are:
#
#     curl -fsSL https://YOURHOST/bootstrap.sh | sh
#
#   • On macOS  -> installs the Asahi UEFI stub (m1n1/U-Boot), then tells you
#                  to reboot into a live Linux and run the one-liner again.
#   • On Linux  -> downloads + runs the full LUKS/debootstrap installer.
#
#  Host this file + debian-asahi-installer.sh (+ optional installer.conf)
#  anywhere static: a GitHub repo's raw URLs, a gist, or your own server.
#  Point BASE_URL at the directory that holds them.
# ===========================================================================
set -eu

# Directory that contains debian-asahi-installer.sh + installer.conf:
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/omtcpublic/omtc/main}"

fetch() {  # fetch <url> <outfile>
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else echo "need curl or wget" >&2; exit 1; fi
}

OS="$(uname -s)"

case "$OS" in
  Darwin)
    cat <<'EOF'
================================================================================
 Phase 1 of 2 (macOS): install the Asahi UEFI stub
================================================================================
 Back up first (Time Machine). This launches the official Asahi installer.
 Choose:  Install an OS -> "UEFI environment only (m1n1 + U-Boot + ESP)"
          and give it the size for ALL of Debian.
 After it finishes, reboot by HOLDING the power button -> pick the new UEFI
 entry, boot a live Asahi-kernel Linux, then run THIS SAME one-liner again.
================================================================================
EOF
    printf 'Launch the Asahi installer now? [y/N] '; read -r a
    [ "$a" = y ] || { echo "Aborted."; exit 0; }
    curl -fsSL https://alx.sh | sh
    echo
    echo ">> Phase 1 done. Reboot into live Linux and re-run the one-liner for phase 2."
    ;;

  Linux)
    echo "Phase 2 of 2 (Linux): fetching and running the installer..."
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    fetch "$BASE_URL/debian-asahi-installer.sh" "$tmp/debian-asahi-installer.sh"
    fetch "$BASE_URL/installer.conf"            "$tmp/installer.conf" 2>/dev/null || true
    chmod +x "$tmp/debian-asahi-installer.sh"
    # -E preserves env (BANANAS_*, DISK, etc. passed on the one-liner).
    if [ "$(id -u)" = 0 ]; then
      exec bash "$tmp/debian-asahi-installer.sh"
    else
      exec sudo -E bash "$tmp/debian-asahi-installer.sh"
    fi
    ;;

  *)
    echo "Unsupported OS: $OS (need macOS for phase 1, Linux for phase 2)" >&2
    exit 1
    ;;
esac
