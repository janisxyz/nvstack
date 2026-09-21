#!/usr/bin/env bash
# nvstack common helpers. Sourced, not executed.
# shellcheck disable=SC2034

NVSTACK_VERSION="${NVSTACK_VERSION:-0.1.0}"
NVSTACK_GITHUB="${NVSTACK_GITHUB:-https://github.com/janisxyz/nvstack}"
NVSTACK_RAW="${NVSTACK_RAW:-https://raw.githubusercontent.com/janisxyz/nvstack}"
NVSTACK_REF="${NVSTACK_REF:-main}"

: "${NVSTACK_YES:=0}"
: "${NVSTACK_DRY_RUN:=1}"
: "${NVSTACK_EXTRAS:=}"
: "${NVSTACK_PROFILE:=}"
: "${NVSTACK_JSON:=0}"
: "${DEBIAN_FRONTEND:=noninteractive}"
export DEBIAN_FRONTEND

if [[ -t 2 ]]; then
  _c_reset=$'\033[0m'
  _c_dim=$'\033[2m'
  _c_bold=$'\033[1m'
  _c_red=$'\033[31m'
  _c_grn=$'\033[32m'
  _c_yel=$'\033[33m'
  _c_cyn=$'\033[36m'
else
  _c_reset="" _c_dim="" _c_bold="" _c_red="" _c_grn="" _c_yel="" _c_cyn=""
fi

_nvstack_log_file=""
_nvstack_init_log() {
  local candidates=()
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    candidates+=("/var/log/nvstack.log")
  fi
  candidates+=("${HOME:-/tmp}/.nvstack.log" "/tmp/nvstack.log")
  local f
  for f in "${candidates[@]}"; do
    if ( umask 022; touch "$f" ) 2>/dev/null; then
      _nvstack_log_file="$f"
      return 0
    fi
  done
}

_nvstack_init_log

_log_raw() {
  local line="$1"
  if [[ -n "${_nvstack_log_file:-}" ]]; then
    printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$line" >>"$_nvstack_log_file" || true
  fi
}

nv_log()  { printf '%s%s%s %s\n' "$_c_dim" "nvstack" "$_c_reset" "$*" >&2; _log_raw "INFO  $*"; }
nv_ok()   { printf '%s%s%s %s\n' "$_c_grn" "nvstack" "$_c_reset" "$*" >&2; _log_raw "OK    $*"; }
nv_warn() { printf '%s%s%s %s\n' "$_c_yel" "nvstack" "$_c_reset" "$*" >&2; _log_raw "WARN  $*"; }
nv_err()  { printf '%s%s%s %s\n' "$_c_red" "nvstack" "$_c_reset" "$*" >&2; _log_raw "ERROR $*"; }
nv_die()  { nv_err "$*"; exit "${2:-1}"; }

nv_require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    nv_die "this command requires root (install/repair/uninstall). re-run with sudo." 1
  fi
}

nv_confirm_or_dry() {
  # Default is dry-run unless --yes. --dry-run wins over --yes if both set.
  if [[ "${NVSTACK_DRY_RUN}" -eq 1 ]]; then
    return 1
  fi
  if [[ "${NVSTACK_YES}" -eq 1 ]]; then
    return 0
  fi
  return 1
}

# Compare dotted versions. nv_ver_ge 550.163 570 -> 1 (false); nv_ver_ge 615 570 -> 0
nv_ver_ge() {
  python3 - "$1" "$2" <<'PY'
import re, sys
def t(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:6]) or (0,)
a, b = sys.argv[1], sys.argv[2]
sys.exit(0 if t(a) >= t(b) else 1)
PY
}

nv_major() {
  python3 -c 'import re,sys; m=re.search(r"\d+", sys.argv[1] or ""); print(m.group(0) if m else "0")' "$1"
}

nv_json_get() {
  # nv_json_get JSON_STRING python_expr_on_obj
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print('"$2"')' "$1"
}

nv_json_file_get() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print('"$2"')' "$1"
}

# Refuse to touch apt/dpkg lock files.
nv_apt_lock_busy() {
  local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
  local f
  for f in "${locks[@]}"; do
    [[ -e "$f" ]] || continue
    if command -v fuser >/dev/null 2>&1 && fuser "$f" >/dev/null 2>&1; then
      return 0
    fi
    if command -v lsof >/dev/null 2>&1 && lsof "$f" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

nv_refuse_apt_lock_kill() {
  if nv_apt_lock_busy; then
    nv_die "apt/dpkg is locked by another process. nvstack will not remove /var/lib/dpkg/lock*. Wait, then retry." 1
  fi
}

nv_run() {
  # Run a command, or print it in dry-run. Never uses eval on untrusted input:
  # callers pass argv.
  if ! nv_confirm_or_dry; then
    printf '+ (dry-run) %s\n' "$*" >&2
    _log_raw "DRY   $*"
    return 0
  fi
  printf '+ %s\n' "$*" >&2
  _log_raw "EXEC  $*"
  "$@"
}

nv_print_banner() {
  printf '%s\n' "nvstack ${NVSTACK_VERSION} — NVIDIA GPU driver stack installer + verifier" >&2
  printf '%s\n' "source policy: ONE package source per run. never mix distro + CUDA repos." >&2
}

PROFILES_HELP="gaming|ai|gen|compute"
