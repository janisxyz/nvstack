#!/usr/bin/env bash
# Run the Python detector and pretty-print.

nv_detect_run() {
  local args=()
  [[ -n "${NVSTACK_MOCK:-}" ]] && args+=(--mock "$NVSTACK_MOCK")
  python3 "${NVSTACK_ROOT}/python/detect.py" "${args[@]}"
}

nv_detect_to_file() {
  local out="$1"
  nv_detect_run >"$out"
}

nv_detect_print_human() {
  local f="$1"
  python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
dist = d["distro"]
print(f"distro     {dist.get('pretty')}  id={dist.get('id')} version={dist.get('version_id')} family={dist.get('family')} support={dist.get('support')}")
k = d["kernel"]
hm = k.get("headers_match")
print(f"kernel     {k.get('release')}  headers_match={hm}")
sb = d["secure_boot"]
en = sb.get("enabled")
print(f"secureboot {'enabled' if en else 'disabled' if en is False else 'unknown'}  method={sb.get('method')}")
gpus = d.get("gpus") or []
if not gpus:
    print("gpu        none detected (lspci -nn -d 10de:)")
else:
    for g in gpus:
        flags = []
        if g.get("open_modules"):
            flags.append("open-modules=yes")
        else:
            flags.append("open-modules=no (proprietary)")
        if g.get("legacy"):
            flags.append("LEGACY")
        if g.get("pre_turing"):
            flags.append("pre-Turing")
        print(
            f"gpu        {g.get('name')}  pci={g.get('pci_id')}  slot={g.get('pci_slot')}  "
            f"arch={g.get('arch')}  min_driver={g.get('min_driver')}  {' '.join(flags)}"
        )
mx = d.get("mixed") or {}
if mx.get("flagged") or (mx.get("standalone_nvidia_smi") and mx.get("nvidia_driver_cuda")):
    print("mixed      YES  standalone nvidia-smi + nvidia-driver-cuda (repair needed)")
elif mx.get("cuda_repo_list"):
    print("mixed      CUDA network repo list present; verify it is the only NVIDIA source")
else:
    print("mixed      no obvious driver/library split")
PY
}

nv_primary_gpu_arch() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); g=d.get("gpus") or [{}]; print((g[0] or {}).get("arch",""))' "$1"
}

nv_primary_gpu() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); g=d.get("gpus") or [None]; import json as J; print(J.dumps(g[0] or {}))' "$1"
}

nv_warn_legacy_gpu() {
  local f="$1"
  python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d.get("gpus") or []:
    if g.get("arch") in {"Kepler", "Fermi"}:
        print("HARD WARNING: Kepler/Fermi and older are legacy-only. nvstack will not claim this card is supported by current AI wheels or nvidia-open.")
        print(f"  {g.get('name')} ({g.get('pci_id')}) last branch ~{g.get('min_driver')}. Expect a black screen if you force a current driver.")
    elif g.get("pre_turing"):
        print(f"WARNING: {g.get('arch')} ({g.get('name')}) cannot use nvidia-open. Proprietary modules only.")
        print("  NVIDIA CUDA repo 580+ dropped Maxwell/Pascal. Prefer distro packages, or pin the 550/570 proprietary branch.")
PY
}
