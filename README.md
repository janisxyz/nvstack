# nvstack

One command installs the **correct NVIDIA GPU driver stack** on Linux for a chosen workload.

It detects the card and the distro, picks **one** coherent package source, and **refuses mixed repos**.

nvstack is an installer + verifier. It is not a game launcher and not a model server.

```
nvidia-container-cli: nvml error: driver/library version mismatch
nvidia-driver-cuda Conflicts: nvidia-smi
```

Those two lines are the entire bug report this tool exists to prevent.

## Clone

```bash
curl -fsSL https://raw.githubusercontent.com/janisxyz/nvstack/main/nvstack | sudo bash -s -- plan --profile ai
```

```bash
git clone https://github.com/janisxyz/nvstack.git
cd nvstack
sudo ./nvstack install --profile ai --yes
```

Default is **dry-run** unless `--yes`. `plan` never mutates the system.

## Why

Debian/Ubuntu ship an NVIDIA driver. NVIDIA ships another one in the CUDA network repo. Guides casually install **both**. The result:

| What you mixed | What you get |
|---|---|
| distro `nvidia-driver` 535 + CUDA-repo `libcuda1` 570 | `nvidia-smi` / NVML **driver/library version mismatch** |
| CUDA-repo `nvidia-driver-cuda` + standalone `nvidia-smi` | `nvidia-driver-cuda Conflicts: nvidia-smi` — apt aborts |
| host mismatch + `nvidia-container-toolkit` | `nvidia-container-cli: nvml error: driver/library version mismatch` then `docker --gpus` lies |

nvstack picks **one** source, pins it, and will not enable docker `--gpus` until host `nvidia-smi` works.

It does **not** wrap the proprietary NVIDIA `.run` installer as the default path.

## Profiles (required, mutually exclusive)

```bash
nvstack plan --profile gaming
nvstack plan --profile ai
nvstack plan --profile gen
nvstack plan --profile compute
```

| Flag | What it installs | What it does not |
|---|---|---|
| `--profile gaming` | Desktop + Vulkan/GL/EGL + 32-bit userspace where the distro provides it. Open kernel modules on Turing and newer. Persistence **off**. | CUDA toolkit, Steam |
| `--profile ai` | Headless compute. `nvidia-driver-cuda` / `nvidia-open` compute packages. `nvidia-persistenced` **on**. | GL stack, `nvidia-smi` standalone package, toolkit, PyTorch, vLLM |
| `--profile gen` | Same compute base as `ai`, plus desktop GL/Vulkan so local UIs can render. | ComfyUI / Forge / model runtimes |
| `--profile compute` | Kernel module + CUDA user-mode + SMI + persistenced. | GL stack |

`--extras docker` (only) installs `nvidia-container-toolkit` from the **container** repo, and **only after** host `nvidia-smi` works. It is not a second driver source.

## Source policy

1. **Distro packages** (Debian non-free / Ubuntu `ubuntu-drivers`) when they are new enough for the GPU **and** the profile.
2. **NVIDIA CUDA network repo** when the distro package is too old (example: Debian 12 `535` on a card that needs `570+` for current AI wheels).

Never both in one run.

If the machine is already mixed, `nvstack repair`:

1. shows `dpkg`/`rpm` NVIDIA packages
2. removes conflicting standalone `nvidia-smi` if the CUDA-repo metapackage provides it
3. tells you to install **one** metapackage set
4. demands a reboot
5. refuses docker `--gpus` until host `nvidia-smi` works

If `nvidia-driver-assistant` exists (or can be installed from the NVIDIA repo), nvstack runs it and **does not ignore** the recommended package set.

## Detection

```bash
nvstack detect
nvstack detect --json
nvstack detect --mock tests/fixtures/4090-debian13
```

- **GPU:** `lspci` + `/sys` + `supported-gpus.json` if present. Prints PCI ID, marketing name, arch (Maxwell / Pascal / Turing / Ampere / Ada / Blackwell / Hopper).
- **Distro:** `/etc/os-release`. First-class: Debian 12/13, Ubuntu 22.04/24.04/26.04. Best-effort: Fedora, Arch. Unknown distro → print exact commands, exit 2.
- **Kernel headers** must match `uname -r` before DKMS.
- **Secure Boot:** detect. If enabled, warn that unsigned DKMS will black-screen unless a MOK is enrolled. nvstack will **not** silently disable Secure Boot.
- **Kepler and older:** legacy-only, hard warning. nvstack does not claim “any card ever made”.

## Commands

```text
nvstack detect
nvstack plan --profile ai
nvstack install --profile ai [--extras docker] [--yes] [--dry-run]
nvstack repair
nvstack status
nvstack uninstall --nouveau
```

- `plan` prints exact packages and the reboot requirement.
- `status` runs `nvidia-smi`, `lsmod`, docker runtime if present, and flags mismatch.
- Logs: `/var/log/nvstack.log`
- Root required for install / repair / uninstall.
- Idempotent: a second `install` on a healthy stack (working `nvidia-smi`) exits 0.
- `DEBIAN_FRONTEND=noninteractive`. nvstack **never** kills apt locks and **never** `rm /var/lib/dpkg/lock*`.

## Reboot rule

A kernel module install is not done until you reboot (or otherwise load a matching module). `nvidia-smi` before reboot is not a verdict. `docker --gpus` before a working host `nvidia-smi` is how you get:

```
nvidia-container-cli: nvml error: driver/library version mismatch
```

## Tests

```bash
bash tests/run.sh
# optional
bats tests/detect.bats tests/plan.bats
```

Fixtures:

| Fixture | What it proves |
|---|---|
| `4090-debian13` | Ada + Debian 13 `550` is too old for `--profile ai` → CUDA repo, `nvidia-driver-cuda`, **no** standalone `nvidia-smi` |
| `5090-ubuntu24` | Blackwell + Ubuntu 24.04 `550` → CUDA repo compute packages |
| `1080ti-debian12` | Pascal legacy branch: distro proprietary, never `nvidia-open` |

## Non-goals

- Windows, WSL-as-primary, macOS
- Default `.run` installer
- Installing CUDA toolkit / PyTorch / vLLM / ComfyUI / Steam unless a profile extra is explicit **and** `--extras` was passed
- Inventing package names when the live index disagrees

## License

MIT. See [CONTRIBUTING.md](CONTRIBUTING.md).
