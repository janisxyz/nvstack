#!/usr/bin/env bash
# Ubuntu 22.04 / 24.04 / 26.04 first-class.

ubuntu_distro_open_pkg() {
  # Prefer ubuntu-drivers if present; else probe common metapackages.
  if [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/ubuntu-drivers" ]]; then
    cat "${NVSTACK_MOCK}/ubuntu-drivers"
    return
  fi
  if command -v ubuntu-drivers >/dev/null 2>&1; then
    ubuntu-drivers list 2>/dev/null || true
  fi
}

ubuntu_best_distro_driver() {
  # Return the highest nvidia-driver-NNN[-open] visible in apt or ubuntu-drivers.
  python3 - "${NVSTACK_MOCK:-}" <<'PY'
import os, re, subprocess, sys
mock = sys.argv[1]
cands = []
if mock and os.path.isfile(os.path.join(mock, "ubuntu-drivers")):
    text = open(os.path.join(mock, "ubuntu-drivers"), encoding="utf-8").read()
    for m in re.finditer(r"nvidia-driver-(\d+)(-open)?", text):
        cands.append((int(m.group(1)), bool(m.group(2)), m.group(0)))
if mock and os.path.isfile(os.path.join(mock, "apt-policy")):
    text = open(os.path.join(mock, "apt-policy"), encoding="utf-8").read()
    for m in re.finditer(r"^(nvidia-driver-\d+(?:-open)?):", text, re.M):
        n = m.group(1)
        mm = re.search(r"(\d+)", n)
        cands.append((int(mm.group(1)), n.endswith("-open"), n))
    # unversioned nvidia-open / nvidia-driver on 26.04-style
    if re.search(r"^nvidia-open:", text, re.M):
        # pull candidate version
        m = re.search(r"^nvidia-open:\n(?:  .*\n)*?  Candidate: ([0-9]+)", text, re.M)
        if m:
            cands.append((int(m.group(1)), True, "nvidia-open"))
if not cands and not mock:
    try:
        out = subprocess.check_output(["ubuntu-drivers","list"], text=True, stderr=subprocess.DEVNULL)
        for m in re.finditer(r"nvidia-driver-(\d+)(-open)?", out):
            cands.append((int(m.group(1)), bool(m.group(2)), m.group(0)))
    except Exception:
        pass
    try:
        out = subprocess.check_output(["bash","-lc","apt-cache search --names-only '^nvidia-driver-[0-9]+'"], text=True, stderr=subprocess.DEVNULL)
        for m in re.finditer(r"nvidia-driver-(\d+)(-open)?", out):
            cands.append((int(m.group(1)), bool(m.group(2)), m.group(0)))
    except Exception:
        pass
if not cands:
    print("")
    raise SystemExit
# prefer higher version; open flavour if present at that version
cands.sort(key=lambda x: (x[0], x[1]))
print(cands[-1][2])
print(cands[-1][0], file=sys.stderr)
PY
}

ubuntu_choose_source() {
  local arch="$1" floor="$2"
  local best ver
  best="$(ubuntu_best_distro_driver 2>/dev/null || true)"
  ver="$(nv_major "${best:-0}")"
  if ! nv_needs_open_modules "$arch"; then
    echo "distro"
    return
  fi
  if [[ -n "$best" ]] && nv_ver_ge "$ver" "$floor"; then
    echo "distro"
  else
    echo "nvidia-cuda"
  fi
}

ubuntu_package_set() {
  local source="$1" arch="$2"
  local pkgs=()
  local rel
  rel="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel"]["release"])' "${NVSTACK_DETECT_JSON}")"
  pkgs+=("linux-headers-${rel}")

  if [[ "$source" == "distro" ]]; then
    local meta
    meta="$(ubuntu_best_distro_driver 2>/dev/null || true)"
    if nv_needs_open_modules "$arch"; then
      if [[ -z "$meta" ]]; then
        if pkg_exists nvidia-open; then
          meta="nvidia-open"
        elif pkg_exists nvidia-driver-570-open; then
          meta="nvidia-driver-570-open"
        elif pkg_exists nvidia-driver-550-open; then
          meta="nvidia-driver-550-open"
        fi
      fi
      if [[ "${NVSTACK_PROFILE}" == "ai" || "${NVSTACK_PROFILE}" == "compute" ]]; then
        # Prefer headless if ubuntu archive provides it for this branch.
        local branch
        branch="$(nv_major "${meta:-nvidia-driver-570-open}")"
        if pkg_exists "nvidia-headless-${branch}-open"; then
          pkgs+=("nvidia-headless-${branch}-open")
        elif pkg_exists nvidia-open; then
          pkgs+=(nvidia-open)
        elif [[ -n "$meta" ]]; then
          pkgs+=("$meta")
        fi
      else
        if [[ -n "$meta" ]]; then
          pkgs+=("$meta")
        elif pkg_exists nvidia-open; then
          pkgs+=(nvidia-open)
        fi
      fi
    else
      # proprietary
      local meta_p
      meta_p="$(ubuntu_best_distro_driver 2>/dev/null || true)"
      meta_p="${meta_p%-open}"
      if [[ -n "$meta_p" ]]; then
        pkgs+=("$meta_p")
      elif pkg_exists nvidia-driver-550; then
        pkgs+=(nvidia-driver-550)
      elif pkg_exists nvidia-driver-535; then
        pkgs+=(nvidia-driver-535)
      fi
    fi
    if nv_profile_wants_persistenced && pkg_exists nvidia-persistenced; then
      pkgs+=(nvidia-persistenced)
    fi
    if nv_profile_wants_i386; then
      pkgs+=(libnvidia-gl:i386 libnvidia-compute:i386)
    fi
  else
    # NVIDIA CUDA repo — Ubuntu now ships unversioned nvidia-open (2025+).
    if nv_needs_open_modules "$arch"; then
      case "${NVSTACK_PROFILE}" in
        gaming)
          pkgs+=(nvidia-open)
          ;;
        ai|compute)
          # Ubuntu CUDA repo has no nvidia-driver-cuda; compute = libnvidia-compute + nvidia-dkms-open
          if pkg_in_nvidia_index libnvidia-compute && pkg_in_nvidia_index nvidia-dkms-open; then
            pkgs+=(libnvidia-compute nvidia-dkms-open)
          elif pkg_in_nvidia_index nvidia-open; then
            pkgs+=(nvidia-open)
          fi
          ;;
        gen)
          pkgs+=(nvidia-open)
          if pkg_in_nvidia_index libnvidia-compute; then
            pkgs+=(libnvidia-compute)
          fi
          ;;
      esac
    else
      pkgs+=(cuda-drivers)
    fi
    if nv_profile_wants_persistenced; then
      pkgs+=(nvidia-persistenced)
    fi
    if nv_profile_wants_i386; then
      pkgs+=(libnvidia-gl:i386 libnvidia-compute:i386)
    fi
  fi

  python3 - "${pkgs[@]}" <<'PY'
import sys
seen=set(); out=[]
for p in sys.argv[1:]:
    if p and p not in seen:
        seen.add(p); out.append(p)
print(" ".join(out))
PY
}

ubuntu_plan() {
  local arch source floor best code nv_ver
  arch="$(nv_primary_gpu_arch "${NVSTACK_DETECT_JSON}")"
  floor="$(nv_profile_floor "$arch")"
  best="$(ubuntu_best_distro_driver 2>/dev/null || true)"
  source="$(ubuntu_choose_source "$arch" "$floor")"
  code="$(nvidia_repo_codename)"
  nv_ver="$(pkg_nvidia_index_latest "$code" nvidia-open)"
  cat <<EOF
source     ${source}
reason     distro best=${best:-(none)}  profile_floor=${floor}  arch=${arch}
nvidia_idx ${code} latest nvidia-open=${nv_ver:-(query failed)}
EOF
  local set
  set="$(ubuntu_package_set "$source" "$arch")"
  printf 'packages   %s\n' "$set"
  printf 'reboot     yes (kernel module + udev + persistenced)\n'
  if [[ "${NVSTACK_EXTRAS}" == *docker* ]]; then
    nvidia_extras_docker_plan
  fi
  printf '%s\n' "$source" >"${NVSTACK_STATE_DIR}/source"
  printf '%s\n' "$set" >"${NVSTACK_STATE_DIR}/packages"
}

ubuntu_install() {
  ubuntu_plan >/dev/null
  local source set_pkgs
  source="$(cat "${NVSTACK_STATE_DIR}/source")"
  set_pkgs="$(cat "${NVSTACK_STATE_DIR}/packages")"
  # shellcheck disable=SC2206
  local pkgs=($set_pkgs)
  if [[ "$source" == "nvidia-cuda" ]]; then
    nvidia_enable_cuda_repo
    nvidia_consult_assistant >/dev/null || true
  fi
  if nv_profile_wants_i386; then
    if ! nv_confirm_or_dry; then
      nv_log "dry-run: dpkg --add-architecture i386"
    else
      dpkg --add-architecture i386 || true
      apt-get update -y || true
    fi
  fi
  pkg_install_apt "${pkgs[@]}" || return 1
  if nv_profile_wants_persistenced; then
    debian_enable_persistenced
  fi
  nv_ok "packages applied from source=${source}. reboot required before nvidia-smi / docker --gpus."
}
