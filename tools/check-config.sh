#!/usr/bin/env bash
#
# Validate the CamillaDSP config on your laptop, before it ever reaches the Pi.
#
#   make check
#
# Why this exists: a bad field in the config takes a full rsync + bootstrap
# round trip to discover otherwise, and `camilladsp --check` gives a precise
# parser error for free. The first version of base.yml shipped an
# `extra_samples` field that 4.x rejects outright -- caught on the Pi, when it
# could have been caught here.
#
# Caveat, stated plainly: the macOS build of CamillaDSP has no ALSA backend, so
# on a Mac this swaps the capture/playback types for file-based ones before
# checking. That still validates everything version-sensitive -- the devices
# scalars, sample format names, filter parameters and pipeline syntax -- but it
# does NOT validate the ALSA device strings themselves. Those are resolved on
# the Pi. On Linux no swap happens and the check is complete.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${TMPDIR:-/tmp}/air-spot-camilladsp"

# shellcheck source=../versions.env
. "$REPO_DIR/versions.env"
# shellcheck source=../config/settings.env
. "$REPO_DIR/config/settings.env"

case "$(uname -s)" in
  Darwin) os=macos; swap=1 ;;
  Linux)  os=linux; swap=0 ;;
  *) echo "unsupported host: $(uname -s)" >&2; exit 2 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=aarch64 ;;
  x86_64)        arch=amd64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 2 ;;
esac

BIN="$CACHE/camilladsp"
if [[ ! -x "$BIN" ]]; then
  asset="camilladsp-${os}-${arch}.tar.gz"
  url="https://github.com/HEnquist/camilladsp/releases/download/${CAMILLADSP_VERSION}/${asset}"
  echo "==> fetching $asset (${CAMILLADSP_VERSION}) for local validation"
  mkdir -p "$CACHE"
  curl -fsSL --retry 3 -o "$CACHE/cdsp.tar.gz" "$url" \
    || { echo "download failed: $url" >&2; exit 1; }
  tar xzf "$CACHE/cdsp.tar.gz" -C "$CACHE"
  chmod +x "$BIN"
fi

# Pin the checker to the version bootstrap installs -- validating against a
# different release would defeat the point.
have="$("$BIN" --version 2>&1 | awk '{print $2}')"
want="${CAMILLADSP_VERSION#v}"
if [[ "$have" != "$want" ]]; then
  echo "==> cached binary is $have, want $want -- refetching"
  rm -rf "$CACHE"; exec "$0" "$@"
fi

staged="$(mktemp)"; trap 'rm -f "$staged" "$staged.chk"' EXIT
sed -e "s/@SAMPLERATE@/${OUTPUT_RATE}/" \
    -e "s|@DAC_DEVICE@|hw:CARD=PLACEHOLDER,DEV=0|" \
    "$REPO_DIR/config/camilladsp/base.yml" > "$staged"
cat "$REPO_DIR/config/camilladsp/filters.yml" >> "$staged"

if grep -q '@[A-Z_]\+@' "$staged"; then
  echo "unsubstituted placeholder(s): $(grep -o '@[A-Z_]\+@' "$staged" | sort -u | tr '\n' ' ')" >&2
  exit 1
fi

if [[ "$swap" == "1" ]]; then
  # base.yml always lists capture before playback, so positional replacement is
  # safe here -- we own the file.
  awk '
    /type: Alsa/ && !seen   { sub(/type: Alsa/, "type: RawFile"); seen=1; print; next }
    /type: Alsa/ && seen    { sub(/type: Alsa/, "type: File");    print; next }
    /device: "hw:Loopback/  { sub(/device: .*/, "filename: \"/dev/zero\""); print; next }
    /device: "hw:CARD=/     { sub(/device: .*/, "filename: \"/dev/null\""); print; next }
    { print }
  ' "$staged" > "$staged.chk"
else
  cp "$staged" "$staged.chk"
fi

echo "==> camilladsp $have --check  (rate ${OUTPUT_RATE})"
if out="$("$BIN" --check "$staged.chk" 2>&1)"; then
  echo "    $(grep -v '^20' <<<"$out" | tail -1)"
  [[ "$swap" == "1" ]] && echo "    note: ALSA device strings not checked on macOS -- resolved on the Pi"
  exit 0
else
  echo
  grep -v '^20' <<<"$out" >&2
  echo >&2
  echo "    config/camilladsp/base.yml + filters.yml" >&2
  exit 1
fi
