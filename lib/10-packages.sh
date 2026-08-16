# shellcheck shell=bash
# apt dependencies + swap. Both are prerequisites for the source builds.

phase "Packages"

# systemd-dev is the Debian 13 addition that 4.x-era shairport-sync guides omit;
# the configure script fails late and confusingly without it.
# libplist-utils is likewise new in the 5.x dependency list.
PACKAGES=(
  build-essential git autoconf automake libtool
  libpopt-dev libconfig-dev libasound2-dev
  avahi-daemon libavahi-client-dev
  libssl-dev libsoxr-dev libplist-dev libplist-utils libsodium-dev
  libavutil-dev libavcodec-dev libavformat-dev
  uuid-dev libgcrypt-dev xxd
  systemd-dev
  alsa-utils curl ca-certificates
  # python3-yaml backs tools/config-split.py, which pulls GUI tuning back into
  # the repo. A real YAML parse is needed because the GUI reserialises configs.
  python3-yaml
  # rfkill for 80-tuning.sh (disabling the unused Wi-Fi radio).
  rfkill
)

missing=()
for p in "${PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
done

if [[ "${#missing[@]}" -eq 0 ]]; then
  skip "all ${#PACKAGES[@]} packages already installed"
else
  info "installing ${#missing[@]} package(s): ${missing[*]}"
  run apt-get update
  DEBIAN_FRONTEND=noninteractive run apt-get install -y --no-install-recommends "${missing[@]}"
  ok "packages installed"
fi

# --- Swap -------------------------------------------------------------------
# 512 MB of RAM against the ffmpeg headers shairport-sync pulls in is not enough.
# Without swap, the compile gets OOM-killed partway through and leaves a mess.
swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
swap_mb=$(( swap_kb / 1024 ))
if (( swap_mb >= 512 )); then
  skip "swap is ${swap_mb} MB, enough"
else
  info "swap is only ${swap_mb} MB -- raising to 1024 MB for the build"
  if [[ -f /etc/dphys-swapfile ]]; then
    run sed -i 's/^#\?CONF_SWAPSIZE=.*/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile
    run sed -i 's/^#\?CONF_MAXSWAP=.*/CONF_MAXSWAP=2048/' /etc/dphys-swapfile
    run systemctl restart dphys-swapfile
    ok "swap raised to 1024 MB"
  else
    warn "no dphys-swapfile; skipping. The build may OOM -- watch for 'cc1: killed'."
  fi
fi
