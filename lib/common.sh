# shellcheck shell=bash
# Shared helpers. Sourced by bootstrap.sh before any phase.

set -euo pipefail

REPO_DIR="${REPO_DIR:?REPO_DIR must be set by bootstrap.sh}"
STATE_DIR=/var/lib/air-spot
BUILD_DIR=/var/tmp/air-spot-build
LOG_FILE=/var/log/air-spot-bootstrap.log

DRY_RUN="${DRY_RUN:-0}"
SKIP_GUI="${SKIP_GUI:-0}"
RECONFIGURE_ONLY="${RECONFIGURE_ONLY:-0}"

# Set by 00-preflight, consumed by 70-config.
DAC_CARD=""
DAC_DEVICE=""

REBOOT_REQUIRED=0

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

log()  { printf '%s  %s\n'      "${C_DIM}$(date +%H:%M:%S)${C_RESET}" "$*"; }
info() { printf '%s  %s\n'      "${C_BLUE}   ..${C_RESET}" "$*"; }
ok()   { printf '%s  %s\n'      "${C_GREEN}   ok${C_RESET}" "$*"; }
skip() { printf '%s  %s\n'      "${C_DIM}   --${C_RESET}" "${C_DIM}$*${C_RESET}"; }
warn() { printf '%s  %s\n'      "${C_YELLOW} warn${C_RESET}" "$*" >&2; }

die() {
  printf '\n%s %s\n\n' "${C_RED}${C_BOLD}FAILED:${C_RESET}" "$*" >&2
  exit 1
}

phase() {
  printf '\n%s\n' "${C_BOLD}==> $*${C_RESET}"
}

# Mark a unit of work as done at a given version, so re-runs can skip it.
stamp_file() { printf '%s/%s.stamp' "$STATE_DIR" "$1"; }

stamp_matches() {
  local name="$1" want="$2" f
  f="$(stamp_file "$name")"
  [[ -f "$f" ]] && [[ "$(cat "$f")" == "$want" ]]
}

write_stamp() {
  local name="$1" val="$2"
  run install -d -m 0755 "$STATE_DIR"
  run_sh "printf '%s' '$val' > '$(stamp_file "$name")'"
}

# run: execute a command, or print it under --dry-run.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s      %s\n' "${C_DIM}" "DRY: $*${C_RESET}"
    return 0
  fi
  "$@"
}

# run_sh: same, for things needing shell interpretation (redirects, pipes).
run_sh() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s      %s\n' "${C_DIM}" "DRY: sh -c $*${C_RESET}"
    return 0
  fi
  bash -c "$*"
}

# Render a template, substituting @TOKEN@ placeholders, and install it only if
# the content actually changed. Returns 0 if changed, 1 if identical --  lets
# callers avoid pointless service restarts.
render() {
  local src="$1" dest="$2" mode="$3"
  shift 3
  local tmp; tmp="$(mktemp)"
  cp "$src" "$tmp"

  # SOH as the sed delimiter -- substituted values contain / and : freely
  # (device paths, URLs), and no template will ever contain a control char.
  # Must be ANSI-C quoted: "\x01" inside ordinary double quotes is a literal
  # backslash, which sed rejects as a delimiter.
  local d=$'\001'
  local pair key val
  for pair in "$@"; do
    key="${pair%%=*}"; val="${pair#*=}"
    sed -i "s${d}@${key}@${d}${val}${d}g" "$tmp"
  done

  if grep -q '@[A-Z_]\+@' "$tmp"; then
    local left; left="$(grep -o '@[A-Z_]\+@' "$tmp" | sort -u | tr '\n' ' ')"
    rm -f "$tmp"
    die "unsubstituted placeholder(s) in $dest: $left"
  fi

  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s      %s\n' "${C_DIM}" "DRY: would write $dest${C_RESET}"
    rm -f "$tmp"
    return 0
  fi

  install -D -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
  return 0
}

need_reboot() { REBOOT_REQUIRED=1; }
