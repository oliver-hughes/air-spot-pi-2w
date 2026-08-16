# shellcheck shell=bash
# CamillaDSP -- prebuilt aarch64 binary, no compile.

phase "CamillaDSP ${CAMILLADSP_VERSION}"

if stamp_matches camilladsp "$CAMILLADSP_VERSION" && [[ -x /usr/local/bin/camilladsp ]]; then
  skip "already at ${CAMILLADSP_VERSION}"
else
  url="https://github.com/HEnquist/camilladsp/releases/download/${CAMILLADSP_VERSION}/${CAMILLADSP_ASSET}"
  tmp="$BUILD_DIR/camilladsp"
  run install -d -m 0755 "$tmp"

  info "downloading ${CAMILLADSP_ASSET}"
  run curl -fsSL --retry 3 -o "$tmp/cdsp.tar.gz" "$url" \
    || die "download failed: $url
Check that ${CAMILLADSP_VERSION} exists and ships ${CAMILLADSP_ASSET}."

  run tar -xzf "$tmp/cdsp.tar.gz" -C "$tmp"
  run install -m 0755 "$tmp/camilladsp" /usr/local/bin/camilladsp

  write_stamp camilladsp "$CAMILLADSP_VERSION"
  ok "installed $(/usr/local/bin/camilladsp --version 2>/dev/null || echo camilladsp)"
fi

# --- Runtime user and directories -------------------------------------------
# Dedicated unprivileged user. 'audio' for ALSA access; the GUI writes configs
# as the same user so ownership stays coherent.
if ! id -u camilladsp >/dev/null 2>&1; then
  run useradd --system --home-dir /var/lib/camilladsp --no-create-home \
      --shell /usr/sbin/nologin --groups audio camilladsp
  ok "created 'camilladsp' service user"
else
  skip "'camilladsp' user exists"
fi

# Give the account a home that actually exists. Belt-and-braces only: every
# path we configure is absolute, but upstream defaults are written as
# ~/camilladsp/... and any code path expanding ~ against a missing directory
# dies with a FileNotFoundError naming the home dir rather than the real fault.
#
# usermod refuses while the user owns a running process, which is the normal
# case on a re-run. Not worth stopping the audio daemon over, so this is
# best-effort: skip when already correct, tolerate failure otherwise.
current_home="$(getent passwd camilladsp | cut -d: -f6)"
if [[ "$current_home" == "/var/lib/camilladsp" ]]; then
  skip "'camilladsp' home already /var/lib/camilladsp"
elif [[ "$DRY_RUN" == "1" ]]; then
  skip "DRY: would set camilladsp home to /var/lib/camilladsp"
elif usermod --home /var/lib/camilladsp camilladsp 2>/dev/null; then
  ok "set 'camilladsp' home to /var/lib/camilladsp"
else
  warn "couldn't change camilladsp's home (services are using the account)."
  warn "Harmless -- all configured paths are absolute. To apply it anyway:"
  warn "  sudo systemctl stop camilladsp camillagui && sudo ./bootstrap.sh --reconfigure"
fi

run install -d -m 0755 -o camilladsp -g camilladsp /etc/camilladsp
run install -d -m 0755 -o camilladsp -g camilladsp /etc/camilladsp/configs
run install -d -m 0755 -o camilladsp -g camilladsp /etc/camilladsp/coeffs

# systemd's StateDirectory= creates this when camilladsp.service starts, but the
# GUI wants to read (and write) the statefile here and may start first.
run install -d -m 0755 -o camilladsp -g camilladsp /var/lib/camilladsp
