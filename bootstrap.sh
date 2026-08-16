#!/usr/bin/env bash
#
# air-spot-pi-2w -- turn a fresh Pi Zero 2 W into an AirPlay 2 target with a
# loudness EQ, outputting over USB to a Fosi ZD3.
#
#   sudo ./bootstrap.sh
#
# Idempotent: re-running is the supported way to apply a config change or pick
# up a version bump. A second run on an unchanged repo takes seconds.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR

usage() {
  cat <<'EOF'
Usage: sudo ./bootstrap.sh [options]

  --reconfigure   Re-render configs and restart services. Skips all source
                  builds. This is what you want after editing filters.yml.
  --skip-gui      Don't install CamillaGUI. Frees ~40 MB of disk and some RAM;
                  tune by editing filters.yml instead.
  --keep-wifi     Don't disable the Wi-Fi radio. Required if you're running
                  this over Wi-Fi rather than ethernet.
  --dry-run       Print what would happen, change nothing.
  -h, --help      This.

Ordinary first run needs no options.
EOF
}

DRY_RUN=0
SKIP_GUI=0
RECONFIGURE_ONLY=0
KEEP_WIFI=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reconfigure) RECONFIGURE_ONLY=1 ;;
    --skip-gui)    SKIP_GUI=1 ;;
    --keep-wifi)   KEEP_WIFI=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
export DRY_RUN SKIP_GUI RECONFIGURE_ONLY KEEP_WIFI

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"
# shellcheck source=versions.env
. "$REPO_DIR/versions.env"
# shellcheck source=config/settings.env
. "$REPO_DIR/config/settings.env"

# Tee everything to a log. Under --dry-run, don't touch /var/log.
if [[ "$DRY_RUN" != "1" && "$(id -u)" == "0" ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

printf '\n%s\n' "${C_BOLD}air-spot-pi-2w${C_RESET}  --  AirPlay 2 + loudness EQ -> Fosi ZD3"
[[ "$DRY_RUN" == "1" ]] && printf '%s\n' "${C_YELLOW}dry run: nothing will be changed${C_RESET}"
[[ "$RECONFIGURE_ONLY" == "1" ]] && printf '%s\n' "${C_DIM}reconfigure only: skipping source builds${C_RESET}"

for ph in \
  00-preflight \
  10-packages \
  20-nqptp \
  30-shairport \
  40-loopback \
  50-camilladsp \
  60-camillagui \
  70-config \
  80-tuning
do
  # shellcheck disable=SC1090
  . "$REPO_DIR/lib/${ph}.sh"
done

# --- Summary ----------------------------------------------------------------
phase "Done"

svc_state() {
  if systemctl is-active --quiet "$1"; then
    printf '%s%s%s' "$C_GREEN" "running" "$C_RESET"
  else
    printf '%s%s%s' "$C_RED" "NOT running" "$C_RESET"
  fi
}

if [[ "$DRY_RUN" != "1" ]]; then
  printf '\n'
  printf '  AirPlay name    %s\n' "${AIRPLAY_NAME:-big}"
  printf '  DAC             %s  (%s)\n' "$DAC_CARD" "$DAC_DEVICE"
  printf '  Sample rate     %s Hz, %s\n' "${OUTPUT_RATE:-48000}" "${OUTPUT_FORMAT:-S32}"
  printf '\n'
  printf '  nqptp           %s\n' "$(svc_state nqptp)"
  printf '  shairport-sync  %s\n' "$(svc_state shairport-sync)"
  printf '  camilladsp      %s\n' "$(svc_state camilladsp)"
  if [[ "$SKIP_GUI" != "1" ]]; then
    printf '  camillagui      %s   http://%s.local:%s/gui/index.html\n' \
      "$(svc_state camillagui)" "${AIRPLAY_NAME:-big}" "${GUI_PORT:-5005}"
  fi
  printf '\n'

  # nqptp not running means AirPlay 2 silently degrades to classic AirPlay --
  # the device still appears and still plays, so this is easy to miss.
  if ! systemctl is-active --quiet nqptp; then
    warn "nqptp is not running: you'll get classic AirPlay, not AirPlay 2."
    warn "Check: journalctl -u nqptp -n 30"
  fi

  cat <<EOF
  ${C_BOLD}Next:${C_RESET}
    1. Play something to "${AIRPLAY_NAME:-big}" from an Apple device.

    2. Confirm the volume bridge works -- this is the one thing the design
       couldn't settle without hardware (DESIGN.md 8):

         journalctl -t air-spot-vol -f

       Move the phone's volume slider. You should see lines appear. If nothing
       does, see docs/TUNING.md "volume bridge fallback".

    3. Set the ZD3's knob and your amp's knob to a normal listening position
       and leave them there. Calibrate reference_level against that -- the
       loudness curve can't see those knobs. See DESIGN.md 8.1.

    4. Tune: docs/TUNING.md
EOF

  if [[ "$REBOOT_REQUIRED" == "1" ]]; then
    printf '\n%s Some changes need a reboot to take effect: sudo reboot\n' "${C_YELLOW}${C_BOLD}!${C_RESET}"
  fi
  printf '\n'
fi
