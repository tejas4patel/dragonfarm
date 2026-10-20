"""Pick the compute device and dtype for a run."""

from dataclasses import dataclass


@dataclass
class Hardware:
    device: object          # torch.device
    device_str: str         # "cuda:0", "mps", "cpu"
    kind: str               # "cuda", "mps", "cpu"
    dtype: object           # torch.dtype
    dtype_name: str
    bf16: bool
    fp16: bool
    device_name: str
    vram_gb: float


# Which models to reach for by default, by GPU memory. Measured on the
# documentation question set (scripts/doc_prototype/RESULTS.md): the 7B in
# 4-bit uses about the memory of a bf16 3B and answers markedly better.
TIERS = [
    {"name": "cpu", "min_vram_gb": 0.0, "model": "Qwen/Qwen2.5-1.5B-Instruct", "load_in_4bit": False,
     "label": "CPU or Apple GPU: 1.5B in full precision; slow but it works"},
    {"name": "small", "min_vram_gb": 3.0, "model": "Qwen/Qwen2.5-1.5B-Instruct", "load_in_4bit": False,
     "label": "under 6 GB: 1.5B"},
    {"name": "medium", "min_vram_gb": 6.0, "model": "Qwen/Qwen2.5-3B-Instruct", "load_in_4bit": False,
     "label": "6 to 8 GB: 3B"},
    {"name": "large", "min_vram_gb": 8.0, "model": "Qwen/Qwen2.5-7B-Instruct", "load_in_4bit": True,
     "label": "8 GB and up: 7B in 4-bit"},
]


# bfloat16 only where the GPU does it in hardware (compute capability 8.0 and
# up). torch.cuda.is_bf16_supported() also says yes when it is emulated, as
# on the T4 that Kaggle and Colab hand out: measured there (3B in 4-bit, the
# example data, 24 steps), the same run took 928 s in bfloat16 and 328 s in
# float16, held-out loss 0.583 and 0.586.
def native_bf16(torch):
    try:
        return bool(torch.cuda.is_bf16_supported(including_emulation=False))
    except TypeError:  # older torch has no including_emulation
        major, _ = torch.cuda.get_device_capability(0)
        return major >= 8 and bool(torch.cuda.is_bf16_supported())


def bitsandbytes_version():
    """Installed bitsandbytes version, or None when it is missing or cannot load."""
    try:
        import bitsandbytes

        return getattr(bitsandbytes, "__version__", "unknown")
    except Exception:
        return None


def model_size_b(model_id):
    """Parameter count in billions guessed from a model id ('Qwen2.5-7B-Instruct' -> 7.0,
    'SmolLM2-135M-Instruct' -> 0.135), or None when the id does not say."""
    import re

    name = str(model_id).rstrip("/").rsplit("/", 1)[-1]
    sizes = []
    for num, unit in re.findall(r"(\d+(?:\.\d+)?)\s*([bBmM])(?![A-Za-z])", name):
        sizes.append(float(num) / (1000.0 if unit.lower() == "m" else 1.0))
    return max(sizes) if sizes else None


def inference_tier(kind, vram_gb, bnb_available):
    """The tier for this machine: the largest whose memory floor fits, falling back
    from the 4-bit tier when bitsandbytes is not usable."""
    if kind != "cuda":
        return dict(TIERS[0])
    # Cards report a little under their nominal size (an "8 GB" RTX 4060 says
    # 7.996 GB), so allow a third of a gigabyte of slack against each floor.
    fit = [t for t in TIERS[1:] if vram_gb + 0.34 >= t["min_vram_gb"]] or [TIERS[1]]
    tier = fit[-1]
    if tier["load_in_4bit"] and not bnb_available:
        tier = [t for t in fit if not t["load_in_4bit"]][-1]
    return dict(tier)


def wants_4bit(setting, model_id, kind, vram_gb, bnb_available=None):
    """Resolve a load_in_4bit setting of True, False, or 'auto' for one model.

    'auto' quantizes only when the model's bf16 weights would not leave room on
    the GPU: estimated at 2.1 GB per billion parameters against 90% of GPU
    memory, so a 7B goes 4-bit on 8 GB and a 3B does not.
    """
    if bnb_available is None:
        bnb_available = bitsandbytes_version() is not None
    if setting in (False, None, "false", "no"):
        return False
    if setting in (True, "true", "yes"):
        if kind != "cuda":
            raise RuntimeError("load_in_4bit needs an NVIDIA GPU; this machine would run on " + kind)
        if not bnb_available:
            raise RuntimeError("load_in_4bit needs the bitsandbytes package, which is not installed in this "
                               "Python environment; run dragon_check() to refresh it")
        return True
    if kind != "cuda" or not bnb_available:
        return False
    size = model_size_b(model_id)
    if size is None:
        return False
    return size * 2.1 > 0.9 * float(vram_gb or 0)


def gpu_memory_gb():
    """(used, free) gigabytes on the first GPU as other processes see it, or
    (None, None). nvidia-smi is asked first because torch's own answer counts
    the CUDA context this process just created; torch is the fallback."""
    import subprocess

    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used,memory.total", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10,
        )
        if out.returncode == 0:
            used_mb, total_mb = [float(x) for x in out.stdout.strip().splitlines()[0].split(",")[:2]]
            return round(used_mb / 1024, 2), round((total_mb - used_mb) / 1024, 2)
    except Exception:
        pass
    try:
        import torch

        free, total = torch.cuda.mem_get_info(0)
        return round((total - free) / 1024**3, 2), round(free / 1024**3, 2)
    except Exception:
        return None, None


def describe():
    """Facts about the machine, used by dragon_check()."""
    import torch

    info = {
        "torch": torch.__version__,
        # None for a CPU-only wheel, e.g. "13.0" for a CUDA build. Reported
        # even when CUDA is unavailable so dragon_check() can say why.
        "torch_cuda_build": torch.version.cuda,
        "cuda_available": torch.cuda.is_available(),
        "mps_available": bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available()),
        "device": "cpu",
        "device_name": "CPU",
        "vram_gb": 0.0,
        "bf16": False,
    }
    if info["cuda_available"]:
        info["device"] = "cuda"
        info["device_name"] = torch.cuda.get_device_name(0)
        info["vram_gb"] = torch.cuda.get_device_properties(0).total_memory / 1024**3
        info["bf16"] = native_bf16(torch)
        info["cuda_version"] = torch.version.cuda
        used, free = gpu_memory_gb()
        info["gpu_used_gb"] = used
        info["gpu_free_gb"] = free
    elif info["mps_available"]:
        info["device"] = "mps"
        info["device_name"] = "Apple MPS"
    info["bitsandbytes"] = bitsandbytes_version()
    info["tier"] = inference_tier(info["device"], info["vram_gb"], info["bitsandbytes"] is not None)
    return info


def resolve(cfg: dict) -> Hardware:
    """Resolve the ``hardware`` block of config.json into concrete choices."""
    import torch

    want = (cfg or {}).get("device", "auto")
    dtype_want = (cfg or {}).get("dtype", "auto")

    cuda_ok = torch.cuda.is_available()
    mps_ok = bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available())

    if want == "auto":
        kind = "cuda" if cuda_ok else "mps" if mps_ok else "cpu"
    elif want == "cuda":
        if not cuda_ok:
            raise RuntimeError("device='cuda' requested but torch.cuda.is_available() is False")
        kind = "cuda"
    elif want == "mps":
        if not mps_ok:
            raise RuntimeError("device='mps' requested but MPS is not available")
        kind = "mps"
    else:
        kind = "cpu"

    if kind == "cuda":
        device = torch.device("cuda:0")
        device_name = torch.cuda.get_device_name(0)
        vram = torch.cuda.get_device_properties(0).total_memory / 1024**3
        bf16_supported = native_bf16(torch)
    elif kind == "mps":
        device = torch.device("mps")
        device_name = "Apple MPS"
        vram = 0.0
        bf16_supported = False
    else:
        device = torch.device("cpu")
        device_name = "CPU"
        vram = 0.0
        bf16_supported = False

    if dtype_want == "auto":
        if kind == "cuda":
            dtype_name = "bfloat16" if bf16_supported else "float16"
        else:
            dtype_name = "float32"
    else:
        dtype_name = dtype_want

    dtype = {"bfloat16": torch.bfloat16, "float16": torch.float16, "float32": torch.float32}[dtype_name]
    return Hardware(
        device=device,
        device_str=str(device),
        kind=kind,
        dtype=dtype,
        dtype_name=dtype_name,
        bf16=(dtype_name == "bfloat16"),
        fp16=(dtype_name == "float16"),
        device_name=device_name,
        vram_gb=vram,
    )
