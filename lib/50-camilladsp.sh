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

# Give the account a home that actually exists. Everything we configure uses
# absolute paths, but upstream defaults are written as ~/camilladsp/... and any
# code path that expands ~ against a missing directory dies with a
# FileNotFoundError that names the home dir rather than the real problem.
run usermod --home /var/lib/camilladsp camilladsp

run install -d -m 0755 -o camilladsp -g camilladsp /etc/camilladsp
run install -d -m 0755 -o camilladsp -g camilladsp /etc/camilladsp/configs
run install -d -m 0755 -o camilladsp -g camilladsp /etc/camilladsp/coeffs

# systemd's StateDirectory= creates this when camilladsp.service starts, but the
# GUI wants to read (and write) the statefile here and may start first.
run install -d -m 0755 -o camilladsp -g camilladsp /var/lib/camilladsp
