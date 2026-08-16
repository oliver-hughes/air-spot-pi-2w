# shellcheck shell=bash
# shairport-sync with AirPlay 2. The long pole -- 10-15 min on a Zero 2 W.

phase "shairport-sync ${SHAIRPORT_SYNC_VERSION}"

if [[ "$RECONFIGURE_ONLY" == "1" ]]; then
  skip "--reconfigure: not rebuilding"
  return 0
fi

if stamp_matches shairport-sync "$SHAIRPORT_SYNC_VERSION" && command -v shairport-sync >/dev/null 2>&1; then
  skip "already at ${SHAIRPORT_SYNC_VERSION}"
  return 0
fi

src="$BUILD_DIR/shairport-sync"
run install -d -m 0755 "$BUILD_DIR"

if [[ -d "$src/.git" ]]; then
  run git -C "$src" fetch --tags --depth 1 origin "$SHAIRPORT_SYNC_VERSION"
  run git -C "$src" checkout -f "$SHAIRPORT_SYNC_VERSION"
  run git -C "$src" clean -xfd
else
  run rm -rf "$src"
  run git clone --depth 1 --branch "$SHAIRPORT_SYNC_VERSION" https://github.com/mikebrady/shairport-sync.git "$src"
fi

# Stop the running service before overwriting its binary.
run systemctl stop shairport-sync 2>/dev/null || true

info "configuring"
# --with-systemd-startup, NOT --with-systemd. Renamed in 5.0; the old flag is
# accepted-but-ignored by some autoconf setups and you end up with no unit file.
run_sh "cd '$src' && autoreconf -fi"
run_sh "cd '$src' && ./configure \
  --sysconfdir=/etc \
  --with-alsa \
  --with-soxr \
  --with-avahi \
  --with-ssl=openssl \
  --with-systemd-startup \
  --with-airplay-2"

info "compiling -- expect 10-15 minutes, and don't be alarmed by the silence"
# -j2, not -j4. Four parallel compiles against the ffmpeg headers will OOM a
# 512 MB board even with swap, and the failure mode ('cc1: killed') is obscure.
run_sh "cd '$src' && make -j2"
run_sh "cd '$src' && make install"

write_stamp shairport-sync "$SHAIRPORT_SYNC_VERSION"

# Verify AirPlay 2 actually got compiled in. The build succeeds happily without
# it if a dependency was missing, and you'd only discover it when the device
# shows up as classic AirPlay weeks later.
if [[ "$DRY_RUN" != "1" ]]; then
  if shairport-sync -V 2>&1 | grep -q 'AirPlay 2'; then
    ok "AirPlay 2 support confirmed in the binary"
  else
    die "shairport-sync built, but WITHOUT AirPlay 2 support.
Version string: $(shairport-sync -V 2>&1)
A dependency was probably missing. Check the configure output above."
  fi
fi

ok "shairport-sync ${SHAIRPORT_SYNC_VERSION} installed"
