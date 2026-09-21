#!/usr/bin/env bash
# Debian 12/13 first-class. Distro non-free vs NVIDIA CUDA repo — never both.

debian_enable_nonfree() {
  if [[ -n "${NVSTACK_MOCK:-}" ]]; then
    nv_log "mock: would enable contrib non-free non-free-firmware"
    return 0
  fi
  if ! nv_confirm_or_dry; then
    nv_log "dry-run: enable contrib non-free non-free-firmware (never CUDA repo in the same run if source=distro)"
    return 0
  fi
  if command -v add-apt-repository >/dev/null 2>&1; then
    add-apt-repository -y contrib
    add-apt-repository -y non-free
    add-apt-repository -y non-free-firmware || true
  else
    nv_warn "add-apt-repository missing; ensure /etc/apt/sources.list has contrib non-free non-free-firmware"
  fi
  apt-get update -y
}

debian_distro_version() {
  # Candidate of nvidia-driver from currently configured (distro) indexes.
  pkg_candidate nvidia-driver
}

debian_choose_source() {
  # Prints: distro|nvidia-cuda
  local arch="$1"
  local floor="$2"
  local distro_ver
  distro_ver="$(debian_distro_version)"
  if [[ -z "$distro_ver" || "$distro_ver" == "(none)" ]]; then
    # Distro package not visible — may need non-free. Still prefer distro if we can enable it
    # unless the GPU floor exceeds known Debian versions.
    if nv_ver_ge "$floor" 570; then
      # Debian 12 is 535, Debian 13 is 550 as of 2026-09. Floor 570 => CUDA repo.
      echo "nvidia-cuda"
      return
    fi
    echo "distro"
    return
  fi
  if nv_needs_open_modules "$arch" && nv_ver_ge "$distro_ver" "$floor"; then
    echo "distro"
    return
  fi
  if ! nv_needs_open_modules "$arch"; then
    # Pascal/Maxwell/Kepler: CUDA 580+ dropped them. Stay on distro.
    echo "distro"
    return
  fi
  if nv_ver_ge "$distro_ver" "$floor"; then
    echo "distro"
  else
    echo "nvidia-cuda"
  fi
}

debian_headers_pkg() {
  local rel
  rel="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel"]["release"])' "${NVSTACK_DETECT_JSON}")"
  echo "linux-headers-${rel}"
}

# Build the package list for Debian + source + profile. Query existence; abort on missing names.
debian_package_set() {
  local source="$1" arch="$2"
  local pkgs=()
  local headers
  headers="$(debian_headers_pkg)"
  pkgs+=("$headers")

  if [[ "$source" == "distro" ]]; then
    pkgs+=(firmware-misc-nonfree)
    if nv_needs_open_modules "$arch" && pkg_exists nvidia-open-kernel-dkms; then
      case "${NVSTACK_PROFILE}" in
        gaming)
          pkgs+=(nvidia-open-kernel-dkms nvidia-driver)
          ;;
        ai|compute)
          if pkg_exists nvidia-driver-cuda; then
            pkgs+=(nvidia-open-kernel-dkms nvidia-driver-cuda)
          else
            pkgs+=(nvidia-open-kernel-dkms nvidia-driver)
          fi
          ;;
        gen)
          pkgs+=(nvidia-open-kernel-dkms nvidia-driver)
          if pkg_exists nvidia-driver-cuda; then
            pkgs+=(nvidia-driver-cuda)
          fi
          ;;
      esac
    else
      # proprietary
      case "${NVSTACK_PROFILE}" in
        gaming)
          pkgs+=(nvidia-kernel-dkms nvidia-driver)
          ;;
        ai|compute)
          if pkg_exists nvidia-driver-cuda; then
            pkgs+=(nvidia-kernel-dkms nvidia-driver-cuda)
          else
            pkgs+=(nvidia-kernel-dkms nvidia-driver)
          fi
          ;;
        gen)
          pkgs+=(nvidia-kernel-dkms nvidia-driver)
          if pkg_exists nvidia-driver-cuda; then
            pkgs+=(nvidia-driver-cuda)
          fi
          ;;
      esac
    fi
    if nv_profile_wants_persistenced && pkg_exists nvidia-persistenced; then
      pkgs+=(nvidia-persistenced)
    fi
    if nv_profile_wants_i386; then
      pkgs+=("nvidia-driver-libs:i386")
    fi
  else
    # NVIDIA CUDA network repo (Debian packaging).
    # Live index: nvidia-driver-cuda Conflicts: nvidia-smi
    local code
    code="$(nvidia_repo_codename)"
    if nv_needs_open_modules "$arch"; then
      case "${NVSTACK_PROFILE}" in
        gaming)
          pkgs+=(nvidia-open)
          ;;
        ai|compute)
          pkgs+=(nvidia-driver-cuda nvidia-kernel-open-dkms)
          ;;
        gen)
          pkgs+=(nvidia-open nvidia-driver-cuda)
          ;;
      esac
    else
      # proprietary CUDA-repo branch. Prefer cuda-drivers / nvidia-driver, never nvidia-open.
      case "${NVSTACK_PROFILE}" in
        gaming)
          pkgs+=(nvidia-driver)
          ;;
        ai|compute)
          pkgs+=(nvidia-driver-cuda cuda-drivers)
          ;;
        gen)
          pkgs+=(nvidia-driver nvidia-driver-cuda)
          ;;
      esac
    fi
    if nv_profile_wants_persistenced; then
      pkgs+=(nvidia-persistenced)
    fi
    if nv_profile_wants_i386; then
      pkgs+=("nvidia-driver-libs:i386")
    fi
    # HARD RULE: never add standalone nvidia-smi when nvidia-driver-cuda is in the set.
    local p
    for p in "${pkgs[@]}"; do
      if [[ "$p" == "nvidia-smi" ]]; then
        nv_die "internal error: standalone nvidia-smi must not be queued (Conflicts: nvidia-driver-cuda)"
      fi
    done
  fi

  # Dedup
  python3 - "${pkgs[@]}" <<'PY'
import sys
seen=set(); out=[]
for p in sys.argv[1:]:
    if p not in seen:
        seen.add(p); out.append(p)
print(" ".join(out))
PY
}

debian_plan() {
  local arch source floor distro_ver code nv_ver
  arch="$(nv_primary_gpu_arch "${NVSTACK_DETECT_JSON}")"
  floor="$(nv_profile_floor "$arch")"
  distro_ver="$(debian_distro_version)"
  source="$(debian_choose_source "$arch" "$floor")"
  code="$(nvidia_repo_codename)"
  nv_ver="$(pkg_nvidia_index_latest "$code" nvidia-open)"
  [[ -z "$nv_ver" ]] && nv_ver="$(pkg_nvidia_index_latest "$code" nvidia-driver)"

  cat <<EOF
source     ${source}
reason     distro nvidia-driver candidate=${distro_ver:-(none)}  profile_floor=${floor}  arch=${arch}
nvidia_idx ${code} latest nvidia-open/nvidia-driver=${nv_ver:-(query failed)}
EOF

  if [[ "$source" == "nvidia-cuda" ]]; then
    local conf
    conf="$(pkg_nvidia_index_conflicts "$code" nvidia-driver-cuda)"
    if [[ "$conf" == *nvidia-smi* ]]; then
      cat <<'EOF'
conflict   nvidia-driver-cuda Conflicts: nvidia-smi
           nvstack will NOT install the standalone nvidia-smi package.
           nvidia-smi is provided by nvidia-driver-cuda.
EOF
    fi
  fi

  local set
  set="$(debian_package_set "$source" "$arch")"
  printf 'packages   %s\n' "$set"
  printf 'reboot     yes (kernel module + udev + persistenced)\n'
  if [[ "${NVSTACK_EXTRAS}" == *docker* ]]; then
    nvidia_extras_docker_plan
  fi
  printf '%s\n' "$source" >"${NVSTACK_STATE_DIR}/source"
  printf '%s\n' "$set" >"${NVSTACK_STATE_DIR}/packages"
}

debian_install() {
  local source arch set_pkgs
  debian_plan >/dev/null
  source="$(cat "${NVSTACK_STATE_DIR}/source")"
  arch="$(nv_primary_gpu_arch "${NVSTACK_DETECT_JSON}")"
  set_pkgs="$(cat "${NVSTACK_STATE_DIR}/packages")"
  # shellcheck disable=SC2206
  local pkgs=($set_pkgs)

  if [[ "$source" == "distro" ]]; then
    debian_enable_nonfree
  else
    nvidia_enable_cuda_repo
    # consult assistant after repo is visible
    local assist
    assist="$(nvidia_consult_assistant || true)"
    if [[ -n "$assist" ]]; then
      nv_log "assistant recommended packages parsed from output (source policy still applies)"
    fi
  fi

  if [[ "$source" == "distro" ]] && nv_profile_wants_i386; then
    if ! nv_confirm_or_dry; then
      nv_log "dry-run: dpkg --add-architecture i386"
    else
      dpkg --add-architecture i386
      apt-get update -y
    fi
  fi

  pkg_install_apt "${pkgs[@]}" || return 1

  if nv_profile_wants_persistenced; then
    debian_enable_persistenced
  fi
  nv_ok "packages applied from source=${source}. reboot required before nvidia-smi / docker --gpus."
}

debian_enable_persistenced() {
  if ! nv_confirm_or_dry; then
    nv_log "dry-run: systemctl enable --now nvidia-persistenced; nvidia-smi -pm 1"
    return 0
  fi
  systemctl enable --now nvidia-persistenced 2>/dev/null || true
  if command -v nvidia-smi >/dev/null; then
    nvidia-smi -pm 1 || true
  fi
}
