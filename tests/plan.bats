#!/usr/bin/env bats
ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
NV="$ROOT/nvstack"

@test "4090 Debian13 --profile ai uses CUDA repo and not standalone nvidia-smi" {
  run "$NV" plan --profile ai --mock "$ROOT/tests/fixtures/4090-debian13"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source     nvidia-cuda"* ]]
  [[ "$output" == *"nvidia-driver-cuda"* ]]
  [[ "$output" == *"nvidia-driver-cuda Conflicts: nvidia-smi"* ]]
  [[ "$output" != *"packages   nvidia-smi"* ]]
}

@test "5090 Ubuntu24 --profile ai uses CUDA compute packages" {
  run "$NV" plan --profile ai --mock "$ROOT/tests/fixtures/5090-ubuntu24"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source     nvidia-cuda"* ]]
  [[ "$output" == *"libnvidia-compute"* ]]
}

@test "1080 Ti Debian12 --profile ai stays on distro proprietary" {
  run "$NV" plan --profile ai --mock "$ROOT/tests/fixtures/1080ti-debian12"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source     distro"* ]]
  [[ "$output" == *"nvidia-kernel-dkms"* ]]
  [[ "$output" != *"nvidia-open "* ]]
}
