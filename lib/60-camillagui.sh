# shellcheck shell=bash
# CamillaGUI -- the web tuning interface.
#
# The 'bundle_*' release asset is fully self-contained: it ships its own Python
# runtime. That sidesteps Debian 13's PEP 668 externally-managed-environment
# restriction entirely -- no venv, no --break-system-packages, no pip at all.

phase "CamillaGUI ${CAMILLAGUI_VERSION}"

if [[ "$SKIP_GUI" == "1" ]]; then
  skip "--skip-gui requested"
  run systemctl disable --now camillagui 2>/dev/null || true
  return 0
fi

GUI_DIR=/opt/camillagui

if stamp_matches camillagui "$CAMILLAGUI_VERSION" && [[ -d "$GUI_DIR" ]]; then
  skip "already at ${CAMILLAGUI_VERSION}"
else
  url="https://github.com/HEnquist/camillagui-backend/releases/download/${CAMILLAGUI_VERSION}/${CAMILLAGUI_ASSET}"
  tmp="$BUILD_DIR/camillagui"
  run rm -rf "$tmp"
  run install -d -m 0755 "$tmp"

  info "downloading ${CAMILLAGUI_ASSET} (~40 MB, it bundles Python)"
  run curl -fsSL --retry 3 -o "$tmp/gui.tar.gz" "$url" \
    || die "download failed: $url"

  run tar -xzf "$tmp/gui.tar.gz" -C "$tmp"

  # The archive may or may not have a single top-level directory depending on
  # how it was packed. Normalise either shape to $GUI_DIR.
  if [[ "$DRY_RUN" != "1" ]]; then
    shopt -s nullglob
    entries=("$tmp"/*/)
    shopt -u nullglob
    rm -rf "$GUI_DIR"
    if [[ "${#entries[@]}" -eq 1 && ! -f "$tmp/camillagui.yml" ]]; then
      mv "${entries[0]}" "$GUI_DIR"
    else
      mkdir -p "$GUI_DIR"
      cp -a "$tmp"/. "$GUI_DIR"/
    fi
  fi

  write_stamp camillagui "$CAMILLAGUI_VERSION"
  ok "installed to $GUI_DIR"
fi

# Locate the launcher -- the bundle's entry point name has moved between releases.
if [[ "$DRY_RUN" != "1" ]]; then
  GUI_BIN=""
  for cand in "$GUI_DIR/camillagui_backend" "$GUI_DIR/main" "$GUI_DIR/camillagui"; do
    [[ -x "$cand" ]] && { GUI_BIN="$cand"; break; }
  done
  [[ -n "$GUI_BIN" ]] || die "can't find the CamillaGUI launcher in $GUI_DIR
Contents: $(ls -1 "$GUI_DIR" | head -20 | tr '\n' ' ')"
  run_sh "printf 'GUI_BIN=%s\n' '$GUI_BIN' > '$STATE_DIR/gui.env'"
  info "launcher: $GUI_BIN"
fi

run chown -R camilladsp:camilladsp "$GUI_DIR"
