#!/usr/bin/env bash
# Live package-index queries. Never invent names. Mock via $NVSTACK_MOCK.

pkg_policy() {
  local name="$1"
  if [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/apt-policy" ]]; then
    python3 - "$name" "${NVSTACK_MOCK}/apt-policy" <<'PY'
import sys
name, path = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read().splitlines()
cur = None
for line in text + [""]:
    if line.startswith(name + ":"):
        if cur is not None:
            break
        cur = [line]
        continue
    if cur is not None:
        if line and not line[0].isspace() and line.endswith(":") and " " not in line.split(":")[0]:
            break
        cur.append(line)
print("\n".join(cur or [f"{name}:\n  Installed: (none)\n  Candidate: (none)"]))
PY
    return
  fi
  if command -v apt-cache >/dev/null 2>&1; then
    apt-cache policy "$name" 2>/dev/null || printf '%s:\n  Installed: (none)\n  Candidate: (none)\n' "$name"
    return
  fi
  printf '%s:\n  Installed: (none)\n  Candidate: (none)\n' "$name"
}

pkg_candidate() {
  local name="$1"
  pkg_policy "$name" | awk '/Candidate:/ {print $2; exit}'
}

pkg_installed() {
  local name="$1"
  pkg_policy "$name" | awk '/Installed:/ {print $2; exit}'
}

pkg_exists() {
  local c
  c="$(pkg_candidate "$1")"
  [[ -n "$c" && "$c" != "(none)" ]]
}

pkg_conflicts_field() {
  local name="$1"
  if [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/nvidia-index" ]]; then
    awk -v n="$name" '$1==n {print $3; for(i=4;i<=NF;i++) printf " %s",$i; print ""; exit}' "${NVSTACK_MOCK}/nvidia-index"
    return
  fi
  if command -v apt-cache >/dev/null 2>&1; then
    apt-cache show "$name" 2>/dev/null | awk '/^Conflicts:/ { $1=""; print; exit }'
  fi
}

pkg_nvidia_index_latest() {
  local distro_key="$1"
  local pkg="$2"
  if [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/nvidia-index" ]]; then
    awk -v n="$pkg" '$1==n {print $2; exit}' "${NVSTACK_MOCK}/nvidia-index"
    return
  fi
  python3 - "$distro_key" "$pkg" <<'PY'
import gzip, re, sys, urllib.request
distro, want = sys.argv[1], sys.argv[2]
url = f"https://developer.download.nvidia.com/compute/cuda/repos/{distro}/x86_64/Packages.gz"
try:
    with urllib.request.urlopen(url, timeout=25) as r:
        blob = gzip.decompress(r.read())
except Exception:
    print("", end="")
    sys.exit(0)
best = None
cur = {}
def verkey(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:6]) or (0,)
for line in blob.decode("utf-8","replace").splitlines() + [""]:
    if line.startswith("Package: "):
        if cur.get("Package") == want:
            v = cur.get("Version","")
            if best is None or verkey(v) > verkey(best):
                best = v
        cur = {"Package": line[9:].strip()}
    elif line.startswith("Version: ") and cur:
        cur["Version"] = line[9:].strip()
if cur.get("Package") == want:
    v = cur.get("Version","")
    if best is None or verkey(v) > verkey(best):
        best = v
print(best or "", end="")
PY
}

pkg_nvidia_index_conflicts() {
  local distro_key="$1" pkg="$2"
  if [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/nvidia-index" ]]; then
    awk -v n="$pkg" '$1==n {$1=""; $2=""; sub(/^  */,""); print; exit}' "${NVSTACK_MOCK}/nvidia-index"
    return
  fi
  python3 - "$distro_key" "$pkg" <<'PY'
import gzip, re, sys, urllib.request
distro, want = sys.argv[1], sys.argv[2]
url = f"https://developer.download.nvidia.com/compute/cuda/repos/{distro}/x86_64/Packages.gz"
try:
    with urllib.request.urlopen(url, timeout=25) as r:
        blob = gzip.decompress(r.read())
except Exception:
    sys.exit(0)
best = None
cur = {}
def verkey(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:6]) or (0,)
for line in blob.decode("utf-8","replace").splitlines() + [""]:
    if line.startswith("Package: "):
        if cur.get("Package") == want:
            v = cur.get("Version","")
            if best is None or verkey(v) > verkey(best[0] if best else ""):
                best = (v, cur.get("Conflicts",""))
        cur = {"Package": line[9:].strip()}
    elif line.startswith("Version: ") and cur:
        cur["Version"] = line[9:].strip()
    elif line.startswith("Conflicts: ") and cur:
        cur["Conflicts"] = line[11:].strip()
if cur.get("Package") == want:
    v = cur.get("Version","")
    if best is None or verkey(v) > verkey(best[0]):
        best = (v, cur.get("Conflicts",""))
print((best or ("",""))[1])
PY
}

nvidia_repo_codename() {
  python3 - "${NVSTACK_DETECT_JSON}" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
fam=d["distro"]["family"]; ver=d["distro"]["version_id"]
if fam=="debian":
    print(f"debian{ver.split('.')[0]}")
elif fam=="ubuntu":
    print("ubuntu"+ver.replace(".",""))
elif fam=="fedora":
    print("fedora"+ver.split(".")[0])
else:
    print("")
PY
}

pkg_in_nvidia_index() {
  local name="$1"
  local code v
  if [[ "$name" == *:i386 ]]; then
    return 0
  fi
  if [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/nvidia-index" ]]; then
    awk -v n="$name" '$1==n {found=1} END{exit found?0:1}' "${NVSTACK_MOCK}/nvidia-index"
    return
  fi
  code="$(nvidia_repo_codename)"
  v="$(pkg_nvidia_index_latest "$code" "$name")"
  [[ -n "$v" ]]
}

pkg_in_source() {
  local source="$1" name="$2"
  if [[ "$source" == "nvidia-cuda" ]]; then
    pkg_in_nvidia_index "$name"
  else
    pkg_exists "$name"
  fi
}

# Simulate an apt install. On failure, print the exact apt error and return 1.
pkg_simulate_apt() {
  local pkgs=("$@")
  if [[ -n "${NVSTACK_MOCK:-}" ]]; then
    local p
    for p in "${pkgs[@]}"; do
      [[ "$p" == *:i386 ]] && continue
      if [[ -f "${NVSTACK_MOCK}/nvidia-index" ]] && awk -v n="$p" '$1==n {found=1} END{exit found?0:1}' "${NVSTACK_MOCK}/nvidia-index"; then
        continue
      fi
      if pkg_exists "$p"; then
        continue
      fi
      cat >&2 <<EOF
E: Unable to locate package ${p}
EOF
      return 1
    done
    printf 'The following NEW packages will be installed:\n'
    printf '  %s\n' "${pkgs[@]}"
    return 0
  fi
  nv_refuse_apt_lock_kill
  local out rc
  set +e
  out="$(apt-get -s -o Debug::NoLocking=1 install --no-install-recommends "${pkgs[@]}" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [[ $rc -ne 0 ]]; then
    nv_err "apt refused this package set. nvstack will not invent replacements."
    nv_err "exact apt error follows:"
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
  if printf '%s' "$out" | grep -q "Conflicts: nvidia-smi"; then
    nv_err "apt reports: nvidia-driver-cuda Conflicts: nvidia-smi"
    nv_err "drop the standalone nvidia-smi package; SMI comes from nvidia-driver-cuda."
    return 1
  fi
  return 0
}

pkg_install_apt() {
  local pkgs=("$@")
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    nv_warn "no packages to install"
    return 0
  fi
  if ! pkg_simulate_apt "${pkgs[@]}"; then
    return 1
  fi
  if ! nv_confirm_or_dry; then
    nv_log "dry-run: would install: ${pkgs[*]}"
    return 0
  fi
  nv_refuse_apt_lock_kill
  apt-get update -y
  if ! apt-get install -y --no-install-recommends \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "${pkgs[@]}"; then
    nv_err "apt-get install failed. refusing to invent alternate package names."
    return 1
  fi
}

pkg_purge_apt() {
  local pkgs=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  if ! nv_confirm_or_dry; then
    nv_log "dry-run: would purge: ${pkgs[*]}"
    return 0
  fi
  nv_refuse_apt_lock_kill
  apt-get purge -y "${pkgs[@]}" || true
}
