#!/usr/bin/env bash
# Enable OR describe the NVIDIA CUDA network repository. Never combine with distro nvidia packages.

nvidia_keyring_url() {
  local code
  code="$(nvidia_repo_codename)"
  [[ -n "$code" ]] || return 1
  printf 'https://developer.download.nvidia.com/compute/cuda/repos/%s/x86_64/cuda-keyring_1.1-1_all.deb\n' "$code"
}

nvidia_repo_pin_note() {
  cat <<'EOF'
Pinning: installing cuda-keyring adds the NVIDIA CUDA network repo at higher priority.
nvstack will not also install Debian non-free / Ubuntu archive NVIDIA packages in this run.
EOF
}

nvidia_enable_cuda_repo() {
  local code url tmp
  code="$(nvidia_repo_codename)"
  [[ -n "$code" ]] || nv_die "cannot map this distro to an NVIDIA CUDA repo path"
  url="$(nvidia_keyring_url)"
  nvidia_repo_pin_note >&2
  if [[ -n "${NVSTACK_MOCK:-}" ]]; then
    nv_log "mock: would install cuda-keyring from $url"
    return 0
  fi
  if [[ -f /etc/apt/sources.list.d/cuda-*.list ]] || grep -Rqs 'developer.download.nvidia.com/compute/cuda' /etc/apt/sources.list.d 2>/dev/null; then
    nv_log "NVIDIA CUDA repo already present"
    return 0
  fi
  if ! nv_confirm_or_dry; then
    nv_log "dry-run: wget $url && dpkg -i cuda-keyring && apt-get update"
    return 0
  fi
  nv_refuse_apt_lock_kill
  tmp="$(mktemp /tmp/cuda-keyring.XXXXXX.deb)"
  if command -v curl >/dev/null; then
    curl -fsSL "$url" -o "$tmp"
  else
    wget -qO "$tmp" "$url"
  fi
  dpkg -i "$tmp"
  apt-get update -y
  rm -f "$tmp"
}

# Consult nvidia-driver-assistant when present or installable from the chosen source.
nvidia_consult_assistant() {
  local out=""
  if [[ -n "${NVSTACK_MOCK:-}" && -f "${NVSTACK_MOCK}/assistant" ]]; then
    out="$(cat "${NVSTACK_MOCK}/assistant")"
    nv_log "nvidia-driver-assistant (mock):"
    printf '%s\n' "$out" >&2
    printf '%s\n' "$out"
    return 0
  fi
  if command -v nvidia-driver-assistant >/dev/null 2>&1; then
    nv_log "consulting nvidia-driver-assistant (output will not be ignored)"
    set +e
    out="$(nvidia-driver-assistant 2>&1)"
    set -e
    printf '%s\n' "$out" >&2
    printf '%s\n' "$out"
    return 0
  fi
  return 0
}

nvidia_assistant_packages() {
  # Extract `apt install ...` package names from assistant text.
  python3 - <<'PY'
import os, re, sys
text = sys.stdin.read()
# sudo apt install -y nvidia-open
pkgs = []
for m in re.finditer(r"apt(?:-get)?(?:\s+-V)?\s+install(?:\s+-y)?\s+(.+)", text):
    raw = m.group(1)
    raw = raw.split("#")[0]
    for tok in raw.split():
        if tok.startswith("-"):
            continue
        pkgs.append(tok)
print(" ".join(pkgs))
PY
}

# Docker extras: NVIDIA container toolkit is a *separate* NVIDIA repo, only with --extras docker,
# and only after host nvidia-smi works.
nvidia_extras_docker_plan() {
  cat <<'EOF'
extras docker:
  source: https://nvidia.github.io/libnvidia-container  (NOT the CUDA driver repo, NOT distro)
  packages: nvidia-container-toolkit
  then: nvidia-ctk runtime configure --runtime=docker
  gate: refused until host `nvidia-smi` works after reboot
EOF
}

nvidia_extras_docker_install() {
  if ! nvidia_host_smi_ok; then
    nv_err "refusing --extras docker: host nvidia-smi does not work yet."
    nv_err "install the driver, reboot, then re-run: nvstack install --profile ${NVSTACK_PROFILE} --extras docker --yes"
    nv_err "this is the mismatch this tool exists to prevent:"
    nv_err "  nvidia-container-cli: nvml error: driver/library version mismatch"
    return 1
  fi
  if ! nv_confirm_or_dry; then
    nv_log "dry-run: would add libnvidia-container repo and install nvidia-container-toolkit"
    nvidia_extras_docker_plan
    return 0
  fi
  nv_refuse_apt_lock_kill
  local distro
  distro="$(. /etc/os-release; echo "${ID}${VERSION_ID}")"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y
  apt-get install -y nvidia-container-toolkit
  if command -v nvidia-ctk >/dev/null && command -v docker >/dev/null; then
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker || true
  fi
}

nvidia_host_smi_ok() {
  if [[ -n "${NVSTACK_MOCK:-}" ]]; then
    [[ -f "${NVSTACK_MOCK}/smi" ]] && grep -q "NVIDIA-SMI" "${NVSTACK_MOCK}/smi" && return 0
    return 1
  fi
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  nvidia-smi >/dev/null 2>&1
}
