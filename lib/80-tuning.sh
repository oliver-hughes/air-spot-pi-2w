# shellcheck shell=bash
# Board- and appliance-level tuning. Everything here is about keeping the audio
# path uninterrupted on hardware that will happily interrupt it.

phase "Tuning"

# --- Wi-Fi ------------------------------------------------------------------
# We're on ethernet. Leaving the radio up costs memory and, more importantly,
# makes Avahi advertise the AirPlay service on two interfaces -- which leads to
# devices intermittently choosing the wrong route and blaming the Pi.
if [[ "${KEEP_WIFI:-0}" == "1" ]]; then
  skip "--keep-wifi: leaving the radio up"
elif [[ -d /sys/class/net/wlan0 ]]; then
  if rfkill list wifi 2>/dev/null | grep -q "Soft blocked: yes"; then
    skip "wifi radio already disabled"
  else
    run rfkill block wifi
    # Persist across reboots: rfkill state is not sticky by itself.
    if render "$REPO_DIR/config/disable-wifi.service" /etc/systemd/system/air-spot-disable-wifi.service 0644; then
      run systemctl daemon-reload
    fi
    run systemctl enable air-spot-disable-wifi >/dev/null 2>&1 || true
    ok "wifi radio disabled (re-enable: sudo systemctl disable --now air-spot-disable-wifi && sudo rfkill unblock wifi)"
  fi
else
  skip "no wlan0 present"
fi

# --- USB autosuspend --------------------------------------------------------
# The ethernet adapter and the DAC share one USB 2.0 bus. A device power-cycling
# mid-stream is a plausible source of the dropouts described in DESIGN.md 9.1,
# and autosuspend buys us nothing on a mains-powered appliance.
if grep -q 'usbcore.autosuspend=-1' /boot/firmware/cmdline.txt 2>/dev/null; then
  skip "usb autosuspend already disabled"
elif [[ -f /boot/firmware/cmdline.txt ]]; then
  run_sh "sed -i 's/\$/ usbcore.autosuspend=-1/' /boot/firmware/cmdline.txt"
  ok "disabled USB autosuspend (takes effect at next boot)"
  need_reboot
else
  warn "no /boot/firmware/cmdline.txt -- skipping USB autosuspend tweak"
fi

# --- DAC mixer --------------------------------------------------------------
# Pin the DAC's own USB volume control to full and leave it there. All
# attenuation belongs to CamillaDSP -- a third stage nobody is tracking would
# make the loudness curve's reference level meaningless (DESIGN.md 8.1).
if [[ "$DRY_RUN" != "1" && -n "$DAC_CARD" ]]; then
  if amixer -c "$DAC_CARD" scontrols 2>/dev/null | grep -q .; then
    while IFS= read -r ctl; do
      [[ -n "$ctl" ]] || continue
      if amixer -c "$DAC_CARD" -q sset "$ctl" 100% unmute 2>/dev/null; then
        info "set '$ctl' to 100% and unmuted"
      fi
    done < <(amixer -c "$DAC_CARD" scontrols 2>/dev/null | sed -n "s/^Simple mixer control '\([^']*\)'.*/\1/p")

    # Persist so it survives a reboot or a replug.
    run_sh "alsactl store '$DAC_CARD' 2>/dev/null || true"
    ok "DAC mixer pinned at full scale"
  else
    skip "DAC exposes no ALSA mixer controls -- nothing to pin"
  fi
fi

# --- SD card longevity ------------------------------------------------------
# An appliance that runs continuously and writes logs to an SD card will
# eventually kill the card. Volatile journald keeps logs in RAM: you still get
# `journalctl` for the current boot, which is what you actually use when
# debugging, without the constant writes.
if [[ -f /etc/systemd/journald.conf.d/air-spot.conf ]]; then
  skip "journald already set to volatile storage"
else
  run install -d -m 0755 /etc/systemd/journald.conf.d
  run_sh "cat > /etc/systemd/journald.conf.d/air-spot.conf <<'EOF'
# Managed by air-spot-pi-2w bootstrap.
# Logs live in RAM. Survives until reboot -- long enough to debug, short enough
# to spare the SD card. Raise or remove if you need logs across reboots.
[Journal]
Storage=volatile
RuntimeMaxUse=32M
EOF"
  run systemctl restart systemd-journald 2>/dev/null || true
  ok "journald set to volatile storage (32M cap)"
fi
