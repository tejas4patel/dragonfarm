"""Which library trains a run (D-35): Unsloth wherever it can, else the
standard transformers + peft trainer.

Unsloth trained the same run 2.6x faster on Kaggle's T4 (3B in 4-bit) with a
third of the GPU memory, and on an 8 GB laptop it stayed on the card where
the standard trainer reserved 11.8 GB and spilled into shared memory. It
needs an NVIDIA GPU and covers plain fine-tuning; everything else, and any
machine where it cannot start, uses the standard trainer, and the run
records which one it used and why.

config.json train.backend (or DRAGONFARM_TRAIN_BACKEND): "auto" (default),
"unsloth", or "transformers".
"""

import importlib.util
import os


def wanted(cfg):
    w = (cfg.get("train", {}).get("backend") or os.environ.get("DRAGONFARM_TRAIN_BACKEND") or "auto").lower()
    return w if w in ("auto", "unsloth", "transformers") else "auto"


def choose(cfg, stage, cuda_available=None, unsloth_installed=None, start=None):
    """Return (backend, note). The note says why the standard trainer is used."""
    want = wanted(cfg)
    if want == "transformers":
        return "transformers", "chosen in the run's settings"
    if stage != "sft":
        return "transformers", f"Unsloth is used for fine-tuning; the {stage} stage uses the standard trainer"
    if cfg.get("model", {}).get("base_adapters"):
        return "transformers", "a run that continues an earlier one uses the standard trainer"
    if unsloth_installed is None:
        unsloth_installed = importlib.util.find_spec("unsloth") is not None
    if not unsloth_installed:
        return "transformers", "Unsloth is not installed in this Python environment"
    if cuda_available is None:
        import torch

        cuda_available = torch.cuda.is_available()
    if not cuda_available:
        return "transformers", "Unsloth needs an NVIDIA GPU"
    err = (start or start_unsloth)()
    if err:
        return "transformers", f"Unsloth could not start here ({err})"
    return "unsloth", None


def start_unsloth():
    """Import Unsloth (it must come before transformers). None, or why not."""
    # Unsloth reports anonymous usage statistics by default: data leaving the
    # machine outside dragonfarm's outbound check, so it is switched off.
    os.environ.setdefault("UNSLOTH_DISABLE_STATISTICS", "1")
    # Its compiled kernels go to one cache next to Hugging Face's, not into
    # whatever folder training started from.
    os.environ.setdefault("UNSLOTH_COMPILE_LOCATION",
                          os.path.join(os.path.expanduser("~"), ".cache", "dragonfarm", "unsloth_compiled_cache"))
    try:
        import unsloth  # noqa: F401
    except Exception as e:  # noqa: BLE001 - any failure means: use the standard trainer
        return f"{type(e).__name__}: {str(e)[:200]}"
    return None


DEFAULT_TARGETS = ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]


def load_policy_unsloth(cfg, hw, status):
    """Base model and a fresh LoRA through Unsloth. Returns (model, tokenizer).

    use_exact_model_name keeps the pinned model and revision: by default
    Unsloth swaps in its own pre-quantised copies, a different repository.
    """
    from unsloth import FastLanguageModel

    m, t, lo = cfg["model"], cfg["train"], cfg["lora"]
    print(f"[dragonfarm] loading {m['id']} with Unsloth", flush=True)
    model, tok = FastLanguageModel.from_pretrained(
        model_name=m["id"], revision=m.get("revision"), max_seq_length=int(t["max_seq_len"]),
        dtype=hw.dtype, load_in_4bit=bool(cfg.get("hardware", {}).get("load_in_4bit", False)),
        trust_remote_code=bool(m.get("trust_remote_code", False)), use_exact_model_name=True,
    )
    targets = lo.get("target_modules", "auto")
    model = FastLanguageModel.get_peft_model(
        model, r=int(lo["r"]), lora_alpha=float(lo["alpha"]), lora_dropout=float(lo["dropout"]),
        target_modules=DEFAULT_TARGETS if targets == "auto" else list(targets), bias="none",
        use_gradient_checkpointing="unsloth" if t.get("gradient_checkpointing", False) else False,
        random_state=int(t.get("seed", 42)),
    )
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    tok.padding_side = "right"
    model._dragonfarm_unsloth = True
    trainable, total = model.get_nb_trainable_parameters()
    status.update(trainable_params=int(trainable), total_params=int(total))
    print(f"[dragonfarm] trainable params {trainable:,} of {total:,}", flush=True)
    return model, tok


def for_inference(model):
    """Switch an Unsloth model to inference mode before samples; no-op otherwise."""
    if getattr(model, "_dragonfarm_unsloth", False):
        from unsloth import FastLanguageModel

        FastLanguageModel.for_inference(model)
