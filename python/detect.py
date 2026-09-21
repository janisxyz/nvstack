#!/usr/bin/env python3
"""nvstack GPU + distro detector. Prints JSON. Honors --mock DIR."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

NVIDIA_VENDOR = "10de"

# Marketing names for the fixtures and common cards. Unknown IDs fall back to lspci.
NAMES: dict[str, str] = {
    "1b06": "GeForce GTX 1080 Ti",
    "1b80": "GeForce GTX 1080",
    "1b81": "GeForce GTX 1070",
    "1c02": "GeForce GTX 1060 3GB",
    "1c03": "GeForce GTX 1060 6GB",
    "1c82": "GeForce GTX 1050 Ti",
    "1e04": "GeForce RTX 2080 Ti",
    "1e82": "GeForce RTX 2080",
    "1e87": "GeForce RTX 2080 SUPER",
    "1f02": "GeForce RTX 2070",
    "1f08": "GeForce RTX 2060 SUPER",
    "1f82": "GeForce RTX 2060",
    "2182": "GeForce GTX 1660 Ti",
    "20b0": "Tesla A100 SXM",
    "20b2": "Tesla A100 PCIe",
    "20b5": "A100 80GB PCIe",
    "2204": "GeForce RTX 3090",
    "2206": "GeForce RTX 3080",
    "2208": "GeForce RTX 3080 Ti",
    "2216": "GeForce RTX 3080 Laptop",
    "2322": "H100 SXM",
    "2330": "H100 PCIe",
    "2331": "H100 NVL",
    "2484": "GeForce RTX 3070",
    "2486": "GeForce RTX 3060 Ti",
    "2488": "GeForce RTX 3070 Ti",
    "2504": "GeForce RTX 3060",
    "2684": "GeForce RTX 4090",
    "2685": "GeForce RTX 4090 D",
    "2702": "GeForce RTX 4080 SUPER",
    "2704": "GeForce RTX 4080",
    "2757": "GeForce RTX 4090 Laptop",
    "2782": "GeForce RTX 4070 Ti",
    "2786": "GeForce RTX 4070",
    "2803": "GeForce RTX 4060 Ti",
    "2882": "GeForce RTX 4060",
    "26b1": "L40S",
    "26b5": "L40",
    "27b8": "RTX 4000 Ada",
    "2b85": "GeForce RTX 5090",
    "2b87": "GeForce RTX 5090 D",
    "2c02": "GeForce RTX 5080",
    "2c18": "GeForce RTX 5090 Laptop",
    "2c19": "GeForce RTX 5080 Laptop",
    "2d04": "GeForce RTX 5060 Ti",
    "2230": "RTX A6000",
    "2231": "RTX A5000",
    "2232": "RTX A4500",
    "2233": "RTX A5500",
    "25b6": "RTX A2000",
}

# Class codes that are GPUs (skip HD-audio / USB).
GPU_CLASSES = {"0300", "0302", "0380"}


def _int(dev: str) -> int:
    return int(dev, 16)


def classify(device: str) -> dict[str, Any]:
    """Map a PCI device id to arch / open-module / min driver / legacy."""
    d = _int(device)
    # Order matters: A100 (0x20B0) sits numerically inside a naive Turing window.
    if d >= 0x2900:
        arch, open_ok, min_drv, legacy = "Blackwell", True, 570, False
    elif 0x2600 <= d <= 0x28FF:
        arch, open_ok, min_drv, legacy = "Ada", True, 520, False
    elif 0x2320 <= d <= 0x23FF:
        arch, open_ok, min_drv, legacy = "Hopper", True, 525, False
    elif 0x20B0 <= d <= 0x20FF:
        arch, open_ok, min_drv, legacy = "Ampere", True, 450, False
    elif 0x2200 <= d <= 0x25FF:
        arch, open_ok, min_drv, legacy = "Ampere", True, 450, False
    elif 0x1E00 <= d <= 0x1FFF or 0x2180 <= d <= 0x21FF:
        arch, open_ok, min_drv, legacy = "Turing", True, 418, False
    elif 0x1D81 <= d <= 0x1DBF:
        arch, open_ok, min_drv, legacy = "Volta", False, 390, False
    elif 0x15F0 <= d <= 0x1D7F:
        arch, open_ok, min_drv, legacy = "Pascal", False, 375, False
    elif 0x1340 <= d <= 0x17FF:
        arch, open_ok, min_drv, legacy = "Maxwell", False, 346, False
    elif 0x0FC0 <= d <= 0x12FF or 0x1000 <= d <= 0x104F:
        arch, open_ok, min_drv, legacy = "Kepler", False, 470, True
    elif d < 0x0FC0:
        arch, open_ok, min_drv, legacy = "Fermi", False, 390, True
    else:
        arch, open_ok, min_drv, legacy = "Unknown", False, 570, False
    return {
        "arch": arch,
        "open_modules": open_ok,
        "min_driver": min_drv,
        "legacy": legacy or arch in {"Kepler", "Fermi"},
        "pre_turing": arch in {"Fermi", "Kepler", "Maxwell", "Pascal", "Volta"},
    }


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _run(cmd: list[str], mock: Path | None, mock_file: str | None = None) -> str:
    if mock is not None and mock_file:
        p = mock / mock_file
        if p.exists():
            return _read(p)
        # allow extension-less names
        for cand in (mock / mock_file, mock / f"{mock_file}.txt"):
            if cand.exists():
                return _read(cand)
        return ""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=False)
        return (r.stdout or "") + (("\n" + r.stderr) if r.stderr and not r.stdout else "")
    except (OSError, subprocess.TimeoutExpired):
        return ""


def parse_os_release(text: str) -> dict[str, Any]:
    kv: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        kv[k] = v.strip().strip('"')
    ident = kv.get("ID", "unknown").lower()
    # Ubuntu derivatives
    like = kv.get("ID_LIKE", "").lower().split()
    version_id = kv.get("VERSION_ID", "")
    major = version_id.split(".")[0] if version_id else ""
    family = "unknown"
    first_class = False
    support = "unknown"
    if ident == "debian" or "debian" in like and ident not in {"ubuntu"}:
        family = "debian"
        if major in {"12", "13"}:
            first_class, support = True, "first-class"
        else:
            support = "best-effort"
    if ident == "ubuntu":
        family = "ubuntu"
        # 22.04 / 24.04 / 26.04
        if version_id in {"22.04", "24.04", "26.04"}:
            first_class, support = True, "first-class"
        else:
            support = "best-effort"
    if ident in {"fedora"} or "fedora" in like:
        family = "fedora"
        support = "best-effort"
    if ident in {"arch", "archarm", "manjaro", "endeavouros"}:
        family = "arch"
        support = "best-effort"
    if ident in {"rhel", "centos", "rocky", "almalinux", "ol"}:
        family = "rhel"
        support = "best-effort"
    return {
        "id": ident,
        "id_like": kv.get("ID_LIKE", ""),
        "version_id": version_id,
        "version_codename": kv.get("VERSION_CODENAME", ""),
        "pretty": kv.get("PRETTY_NAME", ident),
        "family": family,
        "first_class": first_class,
        "support": support,
        "raw": kv,
    }


LSPCI_RE = re.compile(
    r"^(?P<slot>\S+)\s+(?P<cls>[^[]+)\s+\[(?P<class>[0-9a-f]{4})\]:\s+"
    r"(?P<rest>.+?)\s+\[(?P<vendor>[0-9a-f]{4}):(?P<device>[0-9a-f]{4})\]",
    re.IGNORECASE,
)


def parse_lspci(text: str) -> list[dict[str, Any]]:
    gpus: list[dict[str, Any]] = []
    for line in text.splitlines():
        m = LSPCI_RE.search(line)
        if not m:
            # looser: "NVIDIA Corporation ... [10de:2684]"
            loose = re.search(
                r"^(?P<slot>\S+).+\[(?P<vendor>10de):(?P<device>[0-9a-f]{4})\]",
                line,
                re.IGNORECASE,
            )
            if not loose:
                continue
            vendor = loose.group("vendor").lower()
            device = loose.group("device").lower()
            slot = loose.group("slot")
            class_code = "0300"
            rest = line
            cls_name = "VGA compatible controller"
        else:
            vendor = m.group("vendor").lower()
            if vendor != NVIDIA_VENDOR:
                continue
            device = m.group("device").lower()
            slot = m.group("slot")
            class_code = m.group("class").lower()
            rest = m.group("rest")
            cls_name = m.group("cls").strip()
        if class_code not in GPU_CLASSES and "audio" in cls_name.lower():
            continue
        if class_code not in GPU_CLASSES and class_code not in {"0000"}:
            # keep 3D/VGA only; skip USB / serial
            if class_code.startswith("0c") or class_code.startswith("04"):
                continue
        info = classify(device)
        name = NAMES.get(device)
        if not name:
            br = re.search(r"\[([^\[\]]+)\]\s*$", rest)
            if br and not re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{4}", br.group(1), re.I):
                name = br.group(1)
            else:
                # "NVIDIA Corporation AD102 [GeForce RTX 4090]"
                br2 = re.search(r"\[([^\[\]]+)\]", rest)
                name = br2.group(1) if br2 else rest.strip()
        gpus.append(
            {
                "pci_slot": slot,
                "pci_id": f"{vendor}:{device}",
                "vendor": vendor,
                "device": device,
                "class": class_code,
                "name": name,
                **info,
            }
        )
    return gpus


def apply_supported_gpus_json(gpus: list[dict[str, Any]], blob: str) -> None:
    """Overlay marketing names from NVIDIA supported-gpus.json if present."""
    if not blob:
        return
    try:
        data = json.loads(blob)
    except json.JSONDecodeError:
        return
    chips = data.get("chips") or data.get("gpus") or []
    by_id: dict[str, str] = {}
    if isinstance(chips, list):
        for c in chips:
            if not isinstance(c, dict):
                continue
            deid = str(c.get("devid") or c.get("device") or "").lower().replace("0x", "")
            nm = c.get("name") or c.get("gpu") or ""
            if deid and nm:
                by_id[deid] = nm
    elif isinstance(chips, dict):
        for k, v in chips.items():
            deid = str(k).lower().replace("0x", "")
            if isinstance(v, dict):
                by_id[deid] = str(v.get("name") or v.get("gpu") or deid)
    for g in gpus:
        if g["device"] in by_id:
            g["name"] = by_id[g["device"]]
            g["name_source"] = "supported-gpus.json"


def parse_secure_boot(mock: Path | None) -> dict[str, Any]:
    if mock is not None:
        t = _read(mock / "secureboot").strip().lower()
        if t in {"enabled", "on", "1", "true"}:
            return {"enabled": True, "method": "mock"}
        if t in {"disabled", "off", "0", "false", ""}:
            return {"enabled": False, "method": "mock"}
        return {"enabled": None, "method": "mock", "raw": t}
    # mokutil
    out = _run(["mokutil", "--sb-state"], None)
    if "enabled" in out.lower():
        return {"enabled": True, "method": "mokutil", "raw": out.strip()}
    if "disabled" in out.lower():
        return {"enabled": False, "method": "mokutil", "raw": out.strip()}
    # efivar
    efivars = [
        Path("/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"),
        Path("/sys/firmware/efi/vars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c/data"),
    ]
    for p in efivars:
        if p.exists():
            try:
                data = p.read_bytes()
                # EFI variable: 4-byte attributes + 1-byte value
                val = data[-1] if data else 0
                return {"enabled": bool(val), "method": "efivar"}
            except OSError:
                pass
    if Path("/sys/firmware/efi").exists():
        return {"enabled": None, "method": "efi-present-unknown"}
    return {"enabled": False, "method": "bios-or-no-efi"}


def kernel_info(mock: Path | None) -> dict[str, Any]:
    release = _run(["uname", "-r"], mock, "uname").strip() or os.uname().release
    headers_match: bool | None = None
    headers_path = None
    candidates = [
        Path(f"/lib/modules/{release}/build"),
        Path(f"/usr/src/linux-headers-{release}"),
        Path(f"/usr/lib/modules/{release}/build"),
    ]
    if mock is not None:
        t = _read(mock / "headers").strip().lower()
        if t in {"yes", "1", "true", "match"}:
            headers_match = True
        elif t in {"no", "0", "false", "mismatch"}:
            headers_match = False
        headers_path = f"/usr/src/linux-headers-{release}" if headers_match else None
    else:
        for c in candidates:
            if c.exists():
                headers_match = True
                headers_path = str(c)
                break
        else:
            headers_match = False
    return {
        "release": release,
        "headers_match": headers_match,
        "headers_path": headers_path,
    }


def mixed_sources(mock: Path | None) -> dict[str, Any]:
    """Heuristic: both distro nvidia packages and NVIDIA CUDA repo lists present."""
    if mock is not None:
        t = _read(mock / "mixed").strip().lower()
        dpkg = _read(mock / "dpkg-nvidia")
        sources = _read(mock / "sources")
        has_cuda_list = "developer.download.nvidia.com" in sources or "cuda" in sources.lower()
        has_smi_pkg = bool(re.search(r"^ii\s+nvidia-smi\s", dpkg, re.M))
        has_cuda_meta = bool(re.search(r"^ii\s+nvidia-driver-cuda\s", dpkg, re.M))
        return {
            "flagged": t in {"yes", "1", "true"} or (has_smi_pkg and has_cuda_meta),
            "standalone_nvidia_smi": has_smi_pkg,
            "nvidia_driver_cuda": has_cuda_meta,
            "cuda_repo_list": has_cuda_list,
            "dpkg": dpkg,
        }
    sources = ""
    for p in Path("/etc/apt/sources.list.d").glob("*.list"):
        sources += _read(p) + "\n"
    for p in Path("/etc/apt/sources.list.d").glob("*.sources"):
        sources += _read(p) + "\n"
    dpkg = _run(["dpkg-query", "-W", "-f", "${Status} ${Package} ${Version}\n"], None)
    # fallback
    if not dpkg:
        dpkg = _run(["bash", "-lc", "dpkg -l '*nvidia*' '*cuda*' 2>/dev/null | awk 'NR==1 || /^ii/'"], None)
    has_cuda_list = "developer.download.nvidia.com" in sources
    has_smi_pkg = "nvidia-smi" in dpkg
    has_cuda_meta = "nvidia-driver-cuda" in dpkg
    return {
        "flagged": (has_smi_pkg and has_cuda_meta) or False,
        "standalone_nvidia_smi": has_smi_pkg,
        "nvidia_driver_cuda": has_cuda_meta,
        "cuda_repo_list": has_cuda_list,
        "dpkg": dpkg[:8000],
    }


def load_supported_gpus(mock: Path | None) -> str:
    paths = []
    if mock is not None:
        paths.append(mock / "supported-gpus.json")
    paths.extend(
        [
            Path("/usr/share/nvidia/supported-gpus.json"),
            Path("/usr/share/nvidia-driver-assistant/supported-gpus.json"),
            Path("/usr/share/doc/nvidia-driver-assistant/supported-gpus.json"),
        ]
    )
    for p in paths:
        if p.exists():
            return _read(p)
    return ""


def main() -> int:
    ap = argparse.ArgumentParser(prog="nvstack-detect")
    ap.add_argument("--mock", default=os.environ.get("NVSTACK_MOCK") or None)
    ap.add_argument("--pretty", action="store_true")
    args = ap.parse_args()
    mock = Path(args.mock) if args.mock else None
    if mock is not None and not mock.exists():
        print(json.dumps({"error": f"mock dir not found: {mock}"}), file=sys.stderr)
        return 2

    lspci = _run(["lspci", "-nn", "-d", "10de:"], mock, "lspci")
    if not lspci and mock is None:
        lspci = _run(["lspci", "-nn"], None)
        # filter nvidia
        lspci = "\n".join(l for l in lspci.splitlines() if "10de:" in l.lower() or "nvidia" in l.lower())
    os_rel = _run(["cat", "/etc/os-release"], mock, "os-release")
    if not os_rel and mock is None:
        os_rel = _read(Path("/etc/os-release"))

    gpus = parse_lspci(lspci)
    apply_supported_gpus_json(gpus, load_supported_gpus(mock))

    result = {
        "tool": "nvstack",
        "gpus": gpus,
        "gpu_count": len(gpus),
        "distro": parse_os_release(os_rel),
        "kernel": kernel_info(mock),
        "secure_boot": parse_secure_boot(mock),
        "mixed": mixed_sources(mock),
        "mock": str(mock) if mock else None,
    }
    print(json.dumps(result, indent=2 if args.pretty else None, sort_keys=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
