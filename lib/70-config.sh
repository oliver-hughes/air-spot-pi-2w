# shellcheck shell=bash
# Render every config, validate what can be validated, start everything.

phase "Configuration"

# All of these come from config/settings.env, sourced by bootstrap.sh.
# The defaults here are a backstop, not the place to change them.
: "${AIRPLAY_NAME:=big}"
: "${OUTPUT_RATE:=48000}"
: "${OUTPUT_FORMAT:=S32}"
: "${IGNORE_VOLUME_CONTROL:=yes}"
: "${GUI_PORT:=5005}"
: "${GUI_BIND:=0.0.0.0}"

[[ -n "$DAC_DEVICE" ]] || die "no DAC device recorded -- preflight should have set this"

restart_shairport=0
restart_camilladsp=0
restart_gui=0

# --- volume bridge ----------------------------------------------------------
if render "$REPO_DIR/config/vol-bridge.py" /usr/local/bin/air-spot-vol-bridge 0755; then
  ok "installed volume bridge"
else
  skip "volume bridge unchanged"
fi

# --- config splitter (used by `make pull-config`) ---------------------------
if render "$REPO_DIR/tools/config-split.py" /usr/local/bin/air-spot-config-split 0755; then
  ok "installed config splitter"
else
  skip "config splitter unchanged"
fi

# --- shairport-sync ---------------------------------------------------------
if render "$REPO_DIR/config/shairport-sync.conf.tmpl" /etc/shairport-sync.conf 0644 \
     "AIRPLAY_NAME=$AIRPLAY_NAME" \
     "OUTPUT_RATE=$OUTPUT_RATE" \
     "OUTPUT_FORMAT=$OUTPUT_FORMAT" \
     "IGNORE_VOLUME_CONTROL=$IGNORE_VOLUME_CONTROL"; then
  ok "wrote /etc/shairport-sync.conf"
  restart_shairport=1
else
  skip "shairport-sync.conf unchanged"
fi

# --- CamillaDSP config ------------------------------------------------------
# base.yml (rendered) + filters.yml (verbatim) concatenated. Both define
# disjoint top-level keys, so plain concatenation yields valid YAML and avoids
# needing a YAML merge tool on the target.
active=/etc/camilladsp/configs/active.yml
staged="$(mktemp)"

rendered="$(mktemp)"
cp "$REPO_DIR/config/camilladsp/base.yml" "$rendered"
d=$'\001'
sed -i "s${d}@SAMPLERATE@${d}${OUTPUT_RATE}${d}g" "$rendered"
sed -i "s${d}@DAC_DEVICE@${d}${DAC_DEVICE}${d}g" "$rendered"
cat "$rendered" "$REPO_DIR/config/camilladsp/filters.yml" > "$staged"
rm -f "$rendered"

if grep -q '@[A-Z_]\+@' "$staged"; then
  left="$(grep -o '@[A-Z_]\+@' "$staged" | sort -u | tr '\n' ' ')"
  rm -f "$staged"
  die "unsubstituted placeholder(s) in CamillaDSP config: $left"
fi

# Don't silently destroy GUI tuning. If active.yml no longer matches what we
# last generated, someone (probably the GUI, possibly you) has changed it.
guard="$STATE_DIR/active.sha256"
if [[ -f "$active" && -f "$guard" ]]; then
  current="$(sha256sum "$active" | cut -d' ' -f1)"
  if [[ "$current" != "$(cat "$guard")" ]]; then
    warn "$active has been modified since bootstrap last wrote it."
    warn "Backing it up to ${active}.bak before overwriting."
    warn "If that was your GUI tuning, recover it with: make pull-config"
    run cp -a "$active" "${active}.bak"
  fi
fi

if [[ -f "$active" ]] && cmp -s "$staged" "$active"; then
  skip "CamillaDSP config unchanged"
  rm -f "$staged"
else
  if [[ "$DRY_RUN" == "1" ]]; then
    skip "DRY: would write $active"
    rm -f "$staged"
  else
    install -D -m 0644 -o camilladsp -g camilladsp "$staged" "$active"
    rm -f "$staged"
    sha256sum "$active" | cut -d' ' -f1 > "$guard"
    ok "wrote $active"
    restart_camilladsp=1
  fi
fi

# Validate before we try to run it. --check parses the config and exits, which
# turns "the service mysteriously won't start" into a precise parser error
# printed right here.
if [[ "$DRY_RUN" != "1" ]]; then
  if check_out="$(/usr/local/bin/camilladsp --check "$active" 2>&1)"; then
    ok "CamillaDSP config validates"
  else
    die "CamillaDSP rejected the generated config:

$check_out

The config is at $active. If the problem is in the filters or pipeline
section, fix config/camilladsp/filters.yml in the repo and re-run with
--reconfigure."
  fi
fi

# --- CamillaDSP service -----------------------------------------------------
if render "$REPO_DIR/systemd/camilladsp.service" /etc/systemd/system/camilladsp.service 0644; then
  ok "wrote camilladsp.service"
  restart_camilladsp=1
  run systemctl daemon-reload
else
  skip "camilladsp.service unchanged"
fi

# --- shairport-sync service drop-in -----------------------------------------
if render "$REPO_DIR/config/shairport-sync-override.conf" \
     /etc/systemd/system/shairport-sync.service.d/air-spot.conf 0644; then
  ok "wrote shairport-sync drop-in"
  restart_shairport=1
  run systemctl daemon-reload
else
  skip "shairport-sync drop-in unchanged"
fi

# --- CamillaGUI -------------------------------------------------------------
if [[ "$SKIP_GUI" != "1" ]]; then
  if render "$REPO_DIR/config/camillagui.yml.tmpl" /opt/camillagui/camillagui.yml 0644 \
       "GUI_BIND=$GUI_BIND" "GUI_PORT=$GUI_PORT"; then
    ok "wrote camillagui.yml"
    restart_gui=1
  else
    skip "camillagui.yml unchanged"
  fi

  gui_bin=""
  [[ -f "$STATE_DIR/gui.env" ]] && { . "$STATE_DIR/gui.env"; gui_bin="${GUI_BIN:-}"; }
  if [[ -n "$gui_bin" ]]; then
    if render "$REPO_DIR/systemd/camillagui.service" /etc/systemd/system/camillagui.service 0644 \
         "GUI_BIN=$gui_bin"; then
      ok "wrote camillagui.service"
      restart_gui=1
      run systemctl daemon-reload
    else
      skip "camillagui.service unchanged"
    fi
  fi
  run chown -R camilladsp:camilladsp /opt/camillagui
fi

# --- Hostname ---------------------------------------------------------------
current_host="$(hostnamectl --static 2>/dev/null || cat /etc/hostname)"
if [[ "$current_host" != "$AIRPLAY_NAME" ]]; then
  info "hostname is '$current_host', setting to '$AIRPLAY_NAME'"
  run hostnamectl set-hostname "$AIRPLAY_NAME"
  # /etc/hosts must follow or sudo gets slow and avahi gets confused.
  if grep -qE "^127\.0\.1\.1" /etc/hosts; then
    run sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${AIRPLAY_NAME}/" /etc/hosts
  else
    run_sh "printf '127.0.1.1\t%s\n' '$AIRPLAY_NAME' >> /etc/hosts"
  fi
  ok "hostname set to $AIRPLAY_NAME"
else
  skip "hostname already '$AIRPLAY_NAME'"
fi

# --- Start everything -------------------------------------------------------
run systemctl enable avahi-daemon >/dev/null 2>&1 || true
run systemctl enable camilladsp   >/dev/null 2>&1 || true
run systemctl enable shairport-sync >/dev/null 2>&1 || true
[[ "$SKIP_GUI" == "1" ]] || run systemctl enable camillagui >/dev/null 2>&1 || true

# Order matters. CamillaDSP must own the loopback's rate and format before
# shairport-sync opens the other side -- first opener wins, and if
# shairport-sync gets there first with different settings, CamillaDSP will
# fail to open its capture device.
if [[ "$restart_camilladsp" == "1" ]] || ! systemctl is-active --quiet camilladsp; then
  run systemctl restart camilladsp
  ok "camilladsp restarted"
fi

if [[ "$restart_shairport" == "1" ]] || ! systemctl is-active --quiet shairport-sync; then
  run systemctl restart shairport-sync
  ok "shairport-sync restarted"
fi

if [[ "$SKIP_GUI" != "1" ]]; then
  if [[ "$restart_gui" == "1" ]] || ! systemctl is-active --quiet camillagui; then
    run systemctl restart camillagui
    ok "camillagui restarted"
  fi
fi
