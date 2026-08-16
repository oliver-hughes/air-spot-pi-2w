# shellcheck shell=bash
# Refuse to half-configure a machine we don't understand.

phase "Preflight"

[[ "$(id -u)" == "0" ]] || die "run with sudo: sudo ./bootstrap.sh"

# --- Architecture -----------------------------------------------------------
# 64-bit is not a preference. The CamillaDSP and CamillaGUI binaries we install
# are aarch64-only; on armhf there is no prebuilt path and we'd need a Rust
# toolchain on a 512 MB board.
arch="$(uname -m)"
[[ "$arch" == "aarch64" ]] || die \
"architecture is '$arch', need 'aarch64'.

You've most likely flashed the 32-bit image. Re-flash with
Raspberry Pi OS Lite (64-bit) -- see docs/IMAGER.md."

# --- OS ---------------------------------------------------------------------
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${VERSION_ID:-}" != "13" ]]; then
    warn "expected Debian 13 (Trixie), found '${PRETTY_NAME:-unknown}'."
    warn "continuing, but package names and systemd-dev availability may differ."
  fi
else
  warn "no /etc/os-release; can't verify the OS."
fi

# --- Board ------------------------------------------------------------------
model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
info "board: $model"
case "$model" in
  *"Zero 2"*) ;;
  *) warn "not a Pi Zero 2 W. Tuning in 80-tuning.sh is aimed at that board; harmless elsewhere." ;;
esac

# --- Network ----------------------------------------------------------------
# Ethernet is the intended link. Warn (don't fail) if we appear to be on wireless,
# because 80-tuning.sh will disable the Wi-Fi radio and would cut our own SSH session.
if ip -br link show up 2>/dev/null | grep -qE '^(eth|enx|end)'; then
  ok "ethernet link is up"
elif ip -br link show up 2>/dev/null | grep -q '^wlan'; then
  warn "no ethernet detected -- you appear to be connected over Wi-Fi."
  warn "80-tuning.sh disables the Wi-Fi radio, which would drop this session."
  warn "Either plug in ethernet, or re-run with --keep-wifi."
  [[ "${KEEP_WIFI:-0}" == "1" ]] || die "refusing to cut your own connection. Use --keep-wifi to override."
fi

# --- The DAC ----------------------------------------------------------------
# Find a USB audio card. We deliberately match on the USB bus rather than a
# name, so this keeps working if Fosi renames the product string.
if [[ "$RECONFIGURE_ONLY" == "1" && -f "$STATE_DIR/dac.env" ]]; then
  # shellcheck disable=SC1091
  . "$STATE_DIR/dac.env"
  skip "reusing previously detected DAC: $DAC_CARD"
else
  [[ -r /proc/asound/cards ]] || die "no ALSA cards at all -- is snd-usb-audio loaded?"

  mapfile -t usb_cards < <(
    for d in /proc/asound/card*; do
      [[ -e "$d/usbid" ]] || continue
      basename "$(readlink -f "$d")"
    done
  )

  if [[ "${#usb_cards[@]}" -eq 0 ]]; then
    die "no USB audio device found.

Plug the Fosi ZD3 in, set its input to USB, and try again.
Cards currently present:
$(cat /proc/asound/cards)"
  fi

  if [[ "${#usb_cards[@]}" -gt 1 ]]; then
    warn "more than one USB audio device present: ${usb_cards[*]}"
    warn "using the first. Unplug the others if that's wrong."
  fi

  # Resolve to the stable ALSA card *name*, not the index. Indices reshuffle
  # across reboots and hotplug; names don't.
  card_num="${usb_cards[0]#card}"
  # /proc/asound/cards looks like:
  #    1 [ZD3            ]: USB-Audio - Fosi Audio ZD3
  #                         Fosi Audio ZD3 at usb-3f980000.usb-1.3, high speed
  # Two lines per card, and the name field carries square brackets that must be
  # stripped -- 'hw:CARD=[ZD3' is not a valid ALSA device.
  DAC_CARD="$(awk -v n="$card_num" '$1 == n { gsub(/[][]/, "", $2); print $2; exit }' /proc/asound/cards)"
  [[ -n "$DAC_CARD" ]] || die "found USB card $card_num but couldn't read its name from /proc/asound/cards"
  DAC_DESC="$(awk -v n="$card_num" '$1 == n { getline; sub(/^ +/, ""); print; exit }' /proc/asound/cards)"
  DAC_DEVICE="hw:CARD=${DAC_CARD},DEV=0"

  ok "DAC: $DAC_CARD  ($DAC_DESC)"
  info "ALSA device: $DAC_DEVICE"

  run install -d -m 0755 "$STATE_DIR"
  run_sh "printf 'DAC_CARD=%s\nDAC_DEVICE=%s\n' '$DAC_CARD' '$DAC_DEVICE' > '$STATE_DIR/dac.env'"
fi

# --- Confirm the DAC will actually accept our target format -----------------
# Better to find out now than to debug a silent CamillaDSP at 2am.
want_rate="${OUTPUT_RATE:-48000}"
if [[ "$DRY_RUN" != "1" ]]; then
  if params="$(cat "/proc/asound/${DAC_CARD}/stream0" 2>/dev/null)"; then
    if grep -q "\b${want_rate}\b" <<<"$params"; then
      ok "DAC advertises ${want_rate} Hz"
    else
      warn "DAC does not list ${want_rate} Hz among its supported rates."
      warn "Change OUTPUT_RATE in config/settings.env -- see DESIGN.md 3.2"
      warn "Rates it does advertise:"
      grep -o 'Rates: .*' <<<"$params" | sort -u | sed 's/^/      /' >&2 || true
    fi
  else
    skip "can't read the DAC's stream info; skipping rate check"
  fi
fi

# --- Disk -------------------------------------------------------------------
avail_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
(( avail_mb > 1500 )) || die "only ${avail_mb} MB free on /. The shairport-sync build needs ~1.5 GB. Expand the filesystem or use a bigger card."
ok "disk: ${avail_mb} MB free"
