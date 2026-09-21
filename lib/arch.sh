#!/usr/bin/env bash
# Arch — best-effort. Extra / official nvidia packages, never the .run installer.

arch_commands() {
  local arch
  arch="$(nv_primary_gpu_arch "${NVSTACK_DETECT_JSON}")"
  cat <<EOF
distro     Arch (best-effort)
policy     pacman official packages only. do not add the CUDA network repo on top.
kernel     match linux / linux-lts / linux-zen headers to uname -r before DKMS
EOF
  if nv_needs_open_modules "$arch"; then
    cat <<'EOF'
sudo pacman -Syu
sudo pacman -S --needed linux-headers nvidia-open nvidia-utils nvidia-persistenced
# 32-bit (gaming): lib32-nvidia-utils  (requires [multilib])
EOF
  else
    cat <<'EOF'
sudo pacman -Syu
sudo pacman -S --needed linux-headers nvidia nvidia-utils nvidia-persistenced
# nvidia-open does not support this GPU
EOF
  fi
  cat <<'EOF'
sudo systemctl enable --now nvidia-persistenced
reboot required.
EOF
}

arch_plan() {
  arch_commands
  printf 'reboot     yes\n'
}

arch_install() {
  arch_commands
  nv_warn "Arch is best-effort: nvstack prints the exact commands."
  if nv_confirm_or_dry; then
    nv_warn "refusing unattended Arch install in v0.1.0. run the printed commands, then: nvstack status"
  fi
}
