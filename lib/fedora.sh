#!/usr/bin/env bash
# Fedora — best-effort. Print exact commands. Do not mix RPM Fusion + CUDA repo.

fedora_commands() {
  local arch source
  arch="$(nv_primary_gpu_arch "${NVSTACK_DETECT_JSON}")"
  cat <<EOF
distro     Fedora (best-effort)
policy     pick ONE: NVIDIA CUDA network repo  OR  RPM Fusion. never both.

# NVIDIA CUDA repo (preferred when you need current AI wheels):
sudo dnf config-manager addrepo --from-repofile=https://developer.download.nvidia.com/compute/cuda/repos/fedora$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["distro"]["version_id"].split(".")[0])' "${NVSTACK_DETECT_JSON}")/x86_64/cuda-fedora$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["distro"]["version_id"].split(".")[0])' "${NVSTACK_DETECT_JSON}").repo
EOF
  if nv_needs_open_modules "$arch"; then
    cat <<'EOF'
sudo dnf install -y kernel-devel kernel-headers
sudo dnf install -y nvidia-open nvidia-persistenced
# compute-only alternative (no GL): nvidia-driver-cuda + open kernel module stream
EOF
  else
    cat <<'EOF'
sudo dnf install -y kernel-devel kernel-headers
sudo dnf install -y nvidia-driver nvidia-driver-cuda nvidia-persistenced
# do not install nvidia-open on Maxwell/Pascal/Volta
EOF
  fi
  cat <<'EOF'

# RPM Fusion path (desktop Fedora, often good enough for gaming) — abort if CUDA repo is already enabled:
# sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda

reboot required. nvstack will not enable both repositories.
EOF
}

fedora_plan() {
  fedora_commands
  printf 'reboot     yes\n'
}

fedora_install() {
  fedora_commands
  nv_warn "Fedora is best-effort: nvstack prints the exact commands and does not auto-mix repos."
  if nv_confirm_or_dry; then
    nv_warn "refusing unattended Fedora install in v0.1.0. run the printed commands, then: nvstack status"
  fi
}
