#!/usr/bin/env bats
# bats tests/detect.bats
ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
NV="$ROOT/nvstack"

@test "4090 Debian 13 is Ada / first-class" {
  run "$NV" detect --mock "$ROOT/tests/fixtures/4090-debian13"
  [ "$status" -eq 0 ]
  [[ "$output" == *"arch=Ada"* ]]
  [[ "$output" == *"pci=10de:2684"* ]]
  [[ "$output" == *"family=debian support=first-class"* ]]
}

@test "5090 Ubuntu 24.04 is Blackwell with Secure Boot" {
  run "$NV" detect --mock "$ROOT/tests/fixtures/5090-ubuntu24"
  [ "$status" -eq 0 ]
  [[ "$output" == *"arch=Blackwell"* ]]
  [[ "$output" == *"pci=10de:2b85"* ]]
  [[ "$output" == *"secureboot enabled"* ]]
}

@test "1080 Ti Debian 12 is Pascal legacy branch" {
  run "$NV" detect --mock "$ROOT/tests/fixtures/1080ti-debian12"
  [ "$status" -eq 0 ]
  [[ "$output" == *"arch=Pascal"* ]]
  [[ "$output" == *"pre-Turing"* ]]
  [[ "$output" == *"cannot use nvidia-open"* ]]
}
