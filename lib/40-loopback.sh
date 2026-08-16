# shellcheck shell=bash
# snd-aloop: the virtual cable between shairport-sync and CamillaDSP.

phase "ALSA loopback"

# index=7 keeps the loopback out of the way of real cards. If it grabbed a low
# index it could become card 0 and steal 'default', which makes every unrelated
# ALSA tool behave strangely.
#
# pcm_substreams=1 because we have exactly one producer. The default of 8
# creates seven unused substream pairs that only add confusion when reading
# /proc/asound.
MODPROBE_CONF='options snd-aloop index=7 pcm_substreams=1 id=Loopback'

changed=0
if render "$REPO_DIR/config/modprobe-aloop.conf" /etc/modprobe.d/air-spot-aloop.conf 0644 \
     "MODPROBE_OPTIONS=$MODPROBE_CONF"; then
  changed=1
fi

if [[ ! -f /etc/modules-load.d/air-spot-aloop.conf ]]; then
  run_sh "printf 'snd-aloop\n' > /etc/modules-load.d/air-spot-aloop.conf"
  changed=1
fi

if [[ "$changed" == "1" ]]; then
  ok "loopback configured"
else
  skip "loopback already configured"
fi

# Load it now so the rest of bootstrap can validate against a real device,
# rather than deferring everything to a reboot.
if [[ "$DRY_RUN" != "1" ]]; then
  if [[ -d /proc/asound/Loopback ]]; then
    skip "snd-aloop already loaded"
  else
    if modprobe snd-aloop 2>/dev/null; then
      ok "snd-aloop loaded"
    else
      warn "couldn't modprobe snd-aloop now; it will load at next boot"
      need_reboot
    fi
  fi

  # If the module was already loaded with different options, our modprobe.conf
  # won't take effect until reboot. Detect that rather than let it confuse us later.
  if [[ -d /proc/asound/Loopback ]] && ! grep -q '^ *7 ' /proc/asound/cards; then
    warn "loopback is loaded at a different index than configured -- reboot to apply"
    need_reboot
  fi
fi
