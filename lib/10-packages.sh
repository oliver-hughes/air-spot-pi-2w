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
  # libgcrypt20-dev, not libgcrypt-dev as shairport-sync's BUILD.md lists it:
  # the latter is a virtual package, so dpkg-query never reports it installed
  # and we'd re-run apt on every single invocation.
  uuid-dev libgcrypt20-dev xxd
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
# 512 MB of RAM against the ffmpeg headers shairport-sync pulls in is tight.
# Without enough swap the compile gets OOM-killed partway through, and the
# failure ('cc1: killed') doesn't obviously say why.
if [[ "$RECONFIGURE_ONLY" == "1" ]]; then
  skip "--reconfigure: no build, swap irrelevant"
else
  swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
  swap_mb=$(( swap_kb / 1024 ))
  if (( swap_mb >= 512 )); then
    skip "swap is ${swap_mb} MB, enough"
  elif [[ -f /etc/dphys-swapfile ]]; then
    info "swap is ${swap_mb} MB -- raising to 1024 MB for the build"
    run sed -i 's/^#\?CONF_SWAPSIZE=.*/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile
    run sed -i 's/^#\?CONF_MAXSWAP=.*/CONF_MAXSWAP=2048/' /etc/dphys-swapfile
    run systemctl restart dphys-swapfile
    ok "swap raised to 1024 MB"
  elif [[ -n "$(swapon --show=NAME --noheadings 2>/dev/null)" ]]; then
    # Trixie images use zram rather than dphys-swapfile. Compressed swap in RAM
    # is less headroom than a swapfile, but the shairport-sync build at -j2 has
    # been observed to complete on ~400 MB of it.
    info "swap is ${swap_mb} MB via $(swapon --show=NAME --noheadings | tr '\n' ' ')(no dphys-swapfile on this image)"
    info "that has been enough for the -j2 build; watch for 'cc1: killed' if it isn't"
  else
    warn "no swap at all and no dphys-swapfile. The build may well OOM."
    warn "If it dies with 'cc1: killed', add swap and re-run."
  fi
fi
