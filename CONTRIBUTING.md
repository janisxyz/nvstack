# Contributing to nvstack

nvstack exists because mixed NVIDIA package sources produce:

```
nvidia-container-cli: nvml error: driver/library version mismatch
nvidia-driver-cuda Conflicts: nvidia-smi
```

## Do not add a second package source in one PR

This is the project rule. A pull request may:

- teach nvstack about **one** source (Debian non-free, Ubuntu `ubuntu-drivers`, NVIDIA CUDA network repo, RPM Fusion, Arch `[extra]`), or
- improve detection / repair / tests

A pull request may **not**:

- install packages from distro **and** the NVIDIA CUDA network repo in a single `nvstack install` run
- `apt install nvidia-smi` next to `nvidia-driver-cuda` on NVIDIA CUDA Debian/Ubuntu repos
- wrap the proprietary NVIDIA `.run` installer as a default path
- add CUDA toolkit, PyTorch, vLLM, ComfyUI, or Steam unless wired behind `--extras` for an existing profile
- silently disable Secure Boot
- invent package names; query the live index (`apt-cache`, `Packages.gz`). If apt/dnf errors, abort with that exact error.

## Tests

```bash
bash tests/run.sh
# optional
bats tests/detect.bats tests/plan.bats
```

Add a `tests/fixtures/<gpu>-<distro>/` mock (`lspci`, `os-release`, `apt-policy`, `nvidia-index`) for new cards or distros.

## Language

Bash 5 + the small Python 3 detector. No Node. No Rust.
