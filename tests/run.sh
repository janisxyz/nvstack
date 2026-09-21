#!/usr/bin/env bash
# Fixture runner. Does not require bats. Exit 0 if every case matches.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NV="$ROOT/nvstack"
pass=0
fail=0
logdir="$(mktemp -d /tmp/nvstack-tests.XXXXXX)"

check() {
  local name="$1" cmd="$2" pattern="$3"
  local out="$logdir/${name}.out"
  set +e
  bash -c "$cmd" >"$out" 2>&1
  local rc=$?
  set -e
  if grep -E -q -- "$pattern" "$out"; then
    printf 'ok   %s\n' "$name"
    pass=$((pass+1))
  else
    printf 'FAIL %s  (rc=%s) expected /%s/\n' "$name" "$rc" "$pattern"
    sed -n '1,80p' "$out" | sed 's/^/     /'
    fail=$((fail+1))
  fi
}

# detect: 4090 + Debian 13
check detect-4090-arch \
  "$NV detect --mock $ROOT/tests/fixtures/4090-debian13 --json" \
  '"arch": "Ada"'
check detect-4090-pci \
  "$NV detect --mock $ROOT/tests/fixtures/4090-debian13" \
  'pci=10de:2684'
check detect-4090-name \
  "$NV detect --mock $ROOT/tests/fixtures/4090-debian13" \
  'GeForce RTX 4090'
check detect-4090-distro \
  "$NV detect --mock $ROOT/tests/fixtures/4090-debian13" \
  'family=debian support=first-class'

# detect: 5090 + Ubuntu 24.04
check detect-5090-arch \
  "$NV detect --mock $ROOT/tests/fixtures/5090-ubuntu24 --json" \
  '"arch": "Blackwell"'
check detect-5090-pci \
  "$NV detect --mock $ROOT/tests/fixtures/5090-ubuntu24" \
  'pci=10de:2b85'
check detect-5090-sb \
  "$NV detect --mock $ROOT/tests/fixtures/5090-ubuntu24" \
  'secureboot enabled'

# detect: 1080 Ti + Debian 12 legacy
check detect-1080-arch \
  "$NV detect --mock $ROOT/tests/fixtures/1080ti-debian12 --json" \
  '"arch": "Pascal"'
check detect-1080-legacy \
  "$NV detect --mock $ROOT/tests/fixtures/1080ti-debian12" \
  'pre-Turing'
check detect-1080-warn \
  "$NV detect --mock $ROOT/tests/fixtures/1080ti-debian12" \
  'cannot use nvidia-open'

# plan: 4090 Debian13 AI → NVIDIA CUDA repo, no standalone nvidia-smi
check plan-4090-ai-source \
  "$NV plan --profile ai --mock $ROOT/tests/fixtures/4090-debian13" \
  'source     nvidia-cuda'
check plan-4090-ai-cuda \
  "$NV plan --profile ai --mock $ROOT/tests/fixtures/4090-debian13" \
  'nvidia-driver-cuda'
check plan-4090-ai-open-dkms \
  "$NV plan --profile ai --mock $ROOT/tests/fixtures/4090-debian13" \
  'nvidia-kernel-open-dkms'
check plan-4090-ai-persist \
  "$NV plan --profile ai --mock $ROOT/tests/fixtures/4090-debian13" \
  'nvidia-persistenced'
check plan-4090-ai-conflict \
  "$NV plan --profile ai --mock $ROOT/tests/fixtures/4090-debian13" \
  'nvidia-driver-cuda Conflicts: nvidia-smi'
check plan-4090-ai-no-smi-pkg \
  "$NV plan --profile ai --mock $ROOT/tests/fixtures/4090-debian13" \
  'packages   .*nvidia-driver-cuda'

# gaming on 4090 Debian13: distro 550 >= 520
check plan-4090-gaming-source \
  "$NV plan --profile gaming --mock $ROOT/tests/fixtures/4090-debian13" \
  'source     distro'

# 5090 Ubuntu 24 AI: distro 550 < 570 → CUDA repo, no nvidia-smi package
check plan-5090-ai-source \
  "$NV plan --profile ai --mock $ROOT/tests/fixtures/5090-ubuntu24" \
  'source     nvidia-cuda'
check plan-5090-ai-compute \
  "$NV plan --profile ai --mock $ROOT/tests/fixtures/5090-ubuntu24" \
  'libnvidia-compute'
check plan-5090-ai-dkms \
  "$NV plan --profile ai --mock $ROOT/tests/fixtures/5090-ubuntu24" \
  'nvidia-dkms-open'

# 1080 Ti Debian 12 AI: distro proprietary, not nvidia-open
check plan-1080-ai-source \
  "$NV plan --profile ai --mock $ROOT/tests/fixtures/1080ti-debian12" \
  'source     distro'
check plan-1080-ai-prop \
  "$NV plan --profile ai --mock $ROOT/tests/fixtures/1080ti-debian12" \
  'nvidia-kernel-dkms'
check plan-1080-ai-warn \
  "$NV plan --profile ai --mock $ROOT/tests/fixtures/1080ti-debian12" \
  'Pascal'

# extras docker is planned, not mixed into driver source
check plan-4090-docker \
  "$NV plan --profile ai --extras docker --mock $ROOT/tests/fixtures/4090-debian13" \
  'nvidia-container-toolkit'

# repair mixed
check repair-mixed-conflict \
  "$NV repair --mock $ROOT/tests/fixtures/mixed-debian13" \
  'nvidia-driver-cuda Conflicts: nvidia-smi'
check repair-mixed-mismatch \
  "$NV repair --mock $ROOT/tests/fixtures/mixed-debian13" \
  'driver/library version mismatch'
check repair-mixed-purge \
  "$NV repair --mock $ROOT/tests/fixtures/mixed-debian13" \
  'would purge: nvidia-smi'

# status
check status-mixed \
  "$NV status --mock $ROOT/tests/fixtures/mixed-debian13" \
  'MIXED'

# mutually exclusive profile
check profile-required \
  "$NV plan --mock $ROOT/tests/fixtures/4090-debian13" \
  'required: --profile'

# install dry-run default
check install-dry-run \
  "$NV install --profile ai --mock $ROOT/tests/fixtures/4090-debian13" \
  'dry-run: would install'

# compute profile has no GL metapackage nvidia-open on debian cuda
check plan-4090-compute \
  "$NV plan --profile compute --mock $ROOT/tests/fixtures/4090-debian13" \
  'nvidia-driver-cuda nvidia-kernel-open-dkms'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
