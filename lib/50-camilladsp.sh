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
  run useradd --system --no-create-home --shell /usr/sbin/nologin --groups audio camilladsp
  ok "created 'camilladsp' service user"
else
  skip "'camilladsp' user exists"
fi

run install -d -m 0755 -o camilladsp -g camilladsp /etc/camilladsp
run install -d -m 0755 -o camilladsp -g camilladsp /etc/camilladsp/configs
run install -d -m 0755 -o camilladsp -g camilladsp /etc/camilladsp/coeffs
