# shellcheck shell=bash
# nqptp -- the AirPlay 2 timing daemon. shairport-sync needs it running or it
# silently downgrades to classic AirPlay.

phase "nqptp ${NQPTP_VERSION}"

if [[ "$RECONFIGURE_ONLY" == "1" ]]; then
  skip "--reconfigure: not rebuilding"
  return 0
fi

if stamp_matches nqptp "$NQPTP_VERSION" && command -v nqptp >/dev/null 2>&1; then
  skip "already at ${NQPTP_VERSION}"
  return 0
fi

src="$BUILD_DIR/nqptp"
run install -d -m 0755 "$BUILD_DIR"

if [[ -d "$src/.git" ]]; then
  run git -C "$src" fetch --tags --depth 1 origin "$NQPTP_VERSION"
else
  run rm -rf "$src"
  run git clone --depth 1 --branch "$NQPTP_VERSION" https://github.com/mikebrady/nqptp.git "$src"
fi

info "building (this is the quick one)"
run_sh "cd '$src' && autoreconf -fi"
run_sh "cd '$src' && ./configure --with-systemd-startup"
run_sh "cd '$src' && make -j2"
run_sh "cd '$src' && make install"

run systemctl enable nqptp
run systemctl restart nqptp

write_stamp nqptp "$NQPTP_VERSION"
ok "nqptp ${NQPTP_VERSION} installed and running"
