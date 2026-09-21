#!/usr/bin/env bash
# Profile package sets. Mutually exclusive: gaming | ai | gen | compute.

nv_validate_profile() {
  case "${NVSTACK_PROFILE}" in
    gaming|ai|gen|compute) return 0 ;;
    "") nv_die "required: --profile ${PROFILES_HELP}" 2 ;;
    *) nv_die "unknown --profile '${NVSTACK_PROFILE}'. mutually exclusive: ${PROFILES_HELP}" 2 ;;
  esac
}

# Minimum driver the *workload* wants. GPU arch min is applied on top.
nv_profile_floor() {
  local arch="$1"
  case "$arch" in
    Blackwell) echo 570 ;;
    Hopper) echo 525 ;;
    Ada)
      case "${NVSTACK_PROFILE}" in
        ai|gen|compute) echo 570 ;;  # current AI wheels
        *) echo 520 ;;
      esac
      ;;
    Ampere|Turing)
      case "${NVSTACK_PROFILE}" in
        ai|gen|compute) echo 570 ;;
        *) echo 450 ;;
      esac
      ;;
    Pascal|Maxwell|Volta)
      # 580+ dropped these. Floor is "whatever still supports the card".
      echo 535
      ;;
    Kepler|Fermi)
      echo 470
      ;;
    *)
      echo 570
      ;;
  esac
}

nv_needs_open_modules() {
  local arch="$1"
  case "$arch" in
    Turing|Ampere|Ada|Hopper|Blackwell) return 0 ;;
    *) return 1 ;;
  esac
}

nv_profile_wants_gl() {
  case "${NVSTACK_PROFILE}" in
    gaming|gen) return 0 ;;
    *) return 1 ;;
  esac
}

nv_profile_wants_persistenced() {
  case "${NVSTACK_PROFILE}" in
    ai|gen|compute) return 0 ;;
    gaming) return 1 ;;  # optional, off by default
  esac
}

nv_profile_wants_i386() {
  [[ "${NVSTACK_PROFILE}" == "gaming" ]]
}

nv_profile_blurb() {
  case "${NVSTACK_PROFILE}" in
    gaming)
      cat <<'EOF'
profile gaming
  Desktop + Vulkan/GL/EGL + 32-bit userspace where the distro provides it.
  Open kernel modules on Turing and newer.
  Persistence mode optional, off by default.
EOF
      ;;
    ai)
      cat <<'EOF'
profile ai
  Headless compute. Prefer nvidia-driver-cuda / nvidia-open compute packages.
  Install nvidia-persistenced and enable persistence mode.
  nvidia-container-toolkit only with --extras docker.
  Do NOT install standalone nvidia-smi on NVIDIA CUDA Debian/Ubuntu repos
  when it Conflicts with nvidia-driver-cuda. SMI comes from the driver metapackage.
EOF
      ;;
    gen)
      cat <<'EOF'
profile gen
  Same compute base as ai, plus desktop GL/Vulkan so local UIs can render.
  Still no model runtimes (no ComfyUI / Forge / vLLM / PyTorch install).
EOF
      ;;
    compute)
      cat <<'EOF'
profile compute
  Minimal: kernel module + CUDA user-mode + nvidia-smi + persistenced. No GL stack.
EOF
      ;;
  esac
}
