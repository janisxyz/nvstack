#!/usr/bin/env bash
# Repair mixed NVIDIA stacks: distro + CUDA repo, or nvidia-smi vs nvidia-driver-cuda.

nv_show_nvidia_packages() {
  nv_log "installed NVIDIA / CUDA packages:"
  if [[ -n "${NVSTACK_MOCK:-}" ]]; then
    if [[ -f "${NVSTACK_MOCK}/dpkg-nvidia" ]]; then
      cat "${NVSTACK_MOCK}/dpkg-nvidia"
    else
      echo "(mock: none)"
    fi
    return
  fi
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -l '*nvidia*' '*cuda*' 2>/dev/null | awk 'NR==1 || /^ii/' || true
  elif command -v rpm >/dev/null 2>&1; then
    rpm -qa | grep -Ei 'nvidia|cuda' || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Q | grep -Ei 'nvidia|cuda' || true
  fi
}

nv_mixed_detected() {
  python3 - "${NVSTACK_DETECT_JSON}" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
mx=d.get("mixed") or {}
sys.exit(0 if (mx.get("flagged") or (mx.get("standalone_nvidia_smi") and mx.get("nvidia_driver_cuda"))) else 1)
PY
}

nv_repair() {
  nv_print_banner
  nv_show_nvidia_packages

  local family
  family="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["distro"]["family"])' "${NVSTACK_DETECT_JSON}")"

  if [[ -n "${NVSTACK_MOCK:-}" ]]; then
    if grep -q nvidia-smi "${NVSTACK_MOCK}/dpkg-nvidia" 2>/dev/null && grep -q nvidia-driver-cuda "${NVSTACK_MOCK}/dpkg-nvidia" 2>/dev/null; then
      nv_err "detected: standalone nvidia-smi together with nvidia-driver-cuda"
      nv_err "this is the conflict this tool exists to prevent:"
      nv_err "  nvidia-driver-cuda Conflicts: nvidia-smi"
      if [[ -f "${NVSTACK_MOCK}/smi" ]] && grep -qi mismatch "${NVSTACK_MOCK}/smi"; then
        nv_err "  nvidia-container-cli: nvml error: driver/library version mismatch"
      fi
      cat <<'EOF'
repair path:
  1. show dpkg/rpm NVIDIA packages   (done)
  2. remove standalone nvidia-smi    (SMI is provided by nvidia-driver-cuda)
  3. install ONE metapackage set     (see: nvstack plan --profile <p>)
  4. reboot
  5. refuse docker --gpus until host nvidia-smi works
EOF
      pkg_purge_apt nvidia-smi
      printf 'reboot     REQUIRED\n'
      printf 'docker     refused until nvidia-smi works after reboot\n'
      return 0
    fi
  fi

  if command -v dpkg-query >/dev/null 2>&1 || [[ -n "${NVSTACK_MOCK:-}" ]]; then
    local has_smi has_cuda
    has_smi=0
    has_cuda=0
    if [[ -n "${NVSTACK_MOCK:-}" ]]; then
      grep -qE '^ii\s+nvidia-smi' "${NVSTACK_MOCK}/dpkg-nvidia" 2>/dev/null && has_smi=1
      grep -qE '^ii\s+nvidia-driver-cuda' "${NVSTACK_MOCK}/dpkg-nvidia" 2>/dev/null && has_cuda=1
    else
      dpkg-query -W nvidia-smi >/dev/null 2>&1 && has_smi=1 || true
      dpkg-query -W nvidia-driver-cuda >/dev/null 2>&1 && has_cuda=1 || true
    fi
    if [[ $has_smi -eq 1 && $has_cuda -eq 1 ]]; then
      nv_err "nvidia-driver-cuda Conflicts: nvidia-smi"
      nv_log "removing standalone nvidia-smi; SMI must come from nvidia-driver-cuda"
      pkg_purge_apt nvidia-smi
    fi
  fi

  # Driver/library version mismatch
  if [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/smi" ]] && grep -qi "mismatch" "${NVSTACK_MOCK}/smi"; then
    nv_err "nvidia-smi reports driver/library version mismatch"
    nv_err "  nvidia-container-cli: nvml error: driver/library version mismatch"
  elif command -v nvidia-smi >/dev/null 2>&1; then
    local smi
    set +e
    smi="$(nvidia-smi 2>&1)"
    set -e
    if printf '%s' "$smi" | grep -qi "mismatch"; then
      nv_err "nvidia-smi: driver/library version mismatch — mixed packages or stale module"
      nv_err "  nvidia-container-cli: nvml error: driver/library version mismatch"
    fi
  fi

  cat <<'EOF'

repair next:
  nvstack plan --profile <gaming|ai|gen|compute>
  sudo nvstack install --profile <...> --yes
  reboot
  nvstack status          # must show a working nvidia-smi
  # only then:
  sudo nvstack install --profile ai --extras docker --yes

nvstack will not enable docker --gpus until host nvidia-smi works.
EOF
  printf 'reboot     REQUIRED\n'
}

nv_status() {
  nv_print_banner
  nv_detect_print_human "${NVSTACK_DETECT_JSON}"
  echo
  echo "== lsmod =="
  if [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/lsmod" ]]; then
    cat "${NVSTACK_MOCK}/lsmod"
  else
    lsmod 2>/dev/null | grep -E '^nvidia|^nouveau' || echo "(no nvidia/nouveau modules loaded)"
  fi
  echo
  echo "== nvidia-smi =="
  if [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/smi" ]]; then
    cat "${NVSTACK_MOCK}/smi"
  elif command -v nvidia-smi >/dev/null 2>&1; then
    set +e
    nvidia-smi
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      nv_err "nvidia-smi failed (rc=$rc). if this is a mismatch, run: nvstack repair"
    fi
  else
    echo "nvidia-smi not installed (or not on PATH). install a driver metapackage; do not apt install nvidia-smi on CUDA Debian repos."
  fi
  echo
  echo "== persistenced =="
  if [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/persistenced" ]]; then
    cat "${NVSTACK_MOCK}/persistenced"
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl is-enabled nvidia-persistenced 2>/dev/null || echo "nvidia-persistenced: not enabled"
    systemctl is-active nvidia-persistenced 2>/dev/null || true
  fi
  echo
  echo "== docker runtime =="
  if command -v docker >/dev/null 2>&1; then
    docker info 2>/dev/null | grep -i -E 'Runtimes:|Default Runtime' || echo "docker present, nvidia runtime unknown"
  elif [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/docker" ]]; then
    cat "${NVSTACK_MOCK}/docker"
  else
    echo "docker not installed"
  fi
  if command -v nvidia-container-cli >/dev/null 2>&1; then
    set +e
    nvidia-container-cli info >/dev/null 2>&1
    local nrc=$?
    set -e
    if [[ $nrc -ne 0 ]]; then
      nv_err "nvidia-container-cli failed. refuse docker --gpus until host nvidia-smi works."
      nv_err "  nvidia-container-cli: nvml error: driver/library version mismatch"
    fi
  fi
  echo
  echo "== mismatch flags =="
  local bad=0
  if nv_mixed_detected; then
    echo "MIXED: standalone nvidia-smi + nvidia-driver-cuda  → nvstack repair"
    bad=1
  fi
  if [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/smi" ]] && grep -qi mismatch "${NVSTACK_MOCK}/smi"; then
    echo "MISMATCH: driver/library version"
    bad=1
  fi
  if [[ $bad -eq 0 ]]; then
    echo "none detected"
  fi
}

nv_uninstall_nouveau() {
  nv_log "uninstall NVIDIA stack and restore nouveau"
  if [[ -n "${NVSTACK_MOCK:-}" ]]; then
    nv_log "mock: would purge NVIDIA packages, drop CUDA repo lists, un-blacklist nouveau, update initramfs"
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    if ! nv_confirm_or_dry; then
      nv_log "dry-run: apt-get purge '*nvidia*' ; rm CUDA list ; restore nouveau"
      return 0
    fi
    nv_refuse_apt_lock_kill
    dpkg -l | awk '/^ii/ && $2 ~ /nvidia|cuda-drivers/ {print $2}' | xargs -r apt-get purge -y
    rm -f /etc/apt/sources.list.d/cuda*.list /etc/apt/sources.list.d/nvidia-container-toolkit.list || true
    rm -f /etc/modprobe.d/nvidia-blacklists-nouveau.conf /etc/modprobe.d/blacklist-nvidia-nouveau.conf || true
    if command -v update-initramfs >/dev/null; then
      update-initramfs -u
    fi
    apt-get autoremove -y || true
  elif command -v dnf >/dev/null 2>&1; then
    if ! nv_confirm_or_dry; then
      nv_log "dry-run: dnf remove nvidia* ; restore nouveau"
      return 0
    fi
    dnf remove -y 'nvidia*' 'kmod-nvidia*' || true
  elif command -v pacman >/dev/null 2>&1; then
    if ! nv_confirm_or_dry; then
      nv_log "dry-run: pacman -Rns nvidia-open nvidia nvidia-utils nvidia-persistenced"
      return 0
    fi
    pacman -Rns --noconfirm nvidia-open nvidia nvidia-utils nvidia-persistenced 2>/dev/null || true
  fi
  nv_ok "NVIDIA packages purged. reboot to bind nouveau."
}
