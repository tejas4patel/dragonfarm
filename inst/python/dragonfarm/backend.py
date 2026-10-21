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

import contextlib
import importlib.util
import os
import sys
from pathlib import Path


def wanted(cfg):
    w = (cfg.get("train", {}).get("backend") or os.environ.get("DRAGONFARM_TRAIN_BACKEND") or "auto").lower()
    return w if w in ("auto", "unsloth", "transformers") else "auto"


def choose(cfg, stage, cuda_available=None, unsloth_installed=None, start=None):
    """Return (backend, note). The note says why the standard trainer is used."""
    want = wanted(cfg)
    if want == "transformers":
        return "transformers", "chosen in the run's settings"
    if stage not in UNSLOTH_STAGES:
        return "transformers", f"Unsloth is not used for the {stage} stage yet; it uses the standard trainer"
    if cfg.get("model", {}).get("base_adapters") and not (CONTINUES_ON_UNSLOTH or want == "unsloth"):
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
        # Unsloth prints a banner on import; the inference worker speaks JSON
        # on stdout, so anything Unsloth prints goes to stderr.
        with contextlib.redirect_stdout(sys.stderr):
            import unsloth  # noqa: F401
    except Exception as e:  # noqa: BLE001 - any failure means: use the standard trainer
        return f"{type(e).__name__}: {str(e)[:200]}"
    return None


# Stages that train with Unsloth when it can run; each was added after an
# A/B against the standard trainer on the same data.
UNSLOTH_STAGES = ("sft", "reinforce")

# Runs that continue an earlier one fold the earlier adapters into the
# weights first, then train a fresh LoRA, on either trainer (A/B 2026-10-20).
CONTINUES_ON_UNSLOTH = True

DEFAULT_TARGETS = ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]


def load_policy_unsloth(cfg, hw, status, run_dir=None):
    """Base model, earlier-stage adapters folded in, and a fresh LoRA through
    Unsloth. Returns (model, tokenizer).

    use_exact_model_name keeps the pinned model and revision: by default
    Unsloth swaps in its own pre-quantised copies, a different repository.
    """
    from unsloth import FastLanguageModel

    m, t, lo = cfg["model"], cfg["train"], cfg["lora"]
    load_4bit = bool(cfg.get("hardware", {}).get("load_in_4bit", False))
    base_adapters = [Path(run_dir) / p for p in (m.get("base_adapters") or [])]
    if base_adapters and load_4bit:
        raise RuntimeError("chaining from a previous run is not supported with load_in_4bit")
    print(f"[dragonfarm] loading {m['id']} with Unsloth", flush=True)
    model, tok = FastLanguageModel.from_pretrained(
        model_name=m["id"], revision=m.get("revision"), max_seq_length=int(t["max_seq_len"]),
        dtype=hw.dtype, load_in_4bit=load_4bit,
        trust_remote_code=bool(m.get("trust_remote_code", False)), use_exact_model_name=True,
    )
    if base_adapters:
        from .loading import apply_base_adapters

        print(f"[dragonfarm] folding in {len(base_adapters)} earlier adapter(s) from {m.get('base_run')}", flush=True)
        model = apply_base_adapters(model, base_adapters)
        if hasattr(model, "peft_config"):      # left behind by merge_and_unload; get_peft_model would reuse it
            del model.peft_config
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
    """Switch an Unsloth model to inference mode before generating; no-op otherwise."""
    if getattr(model, "_dragonfarm_unsloth", False):
        from unsloth import FastLanguageModel

        FastLanguageModel.for_inference(model)


def for_training(model):
    """Switch an Unsloth model back to training mode; no-op otherwise."""
    if getattr(model, "_dragonfarm_unsloth", False):
        from unsloth import FastLanguageModel

        FastLanguageModel.for_training(model)


# Answering, Chat and question writing (the inference worker) use today's
# loader by default. In the A/B (FDA questions, 2026-10-20) Unsloth gave the
# same grades and was faster on short prompts, but slower on long document
# prompts (up to 50 s against 15 s) and about 10-25 s slower to load, so
# slower overall on the 7B. DRAGONFARM_INFER_BACKEND=unsloth turns it on.
INFER_ON_UNSLOTH = False


def choose_inference(req, cuda_available=None, unsloth_installed=None, start=None):
    want = (os.environ.get("DRAGONFARM_INFER_BACKEND") or "auto").lower()
    if want == "transformers":
        return "transformers", "chosen in the environment"
    if want != "unsloth" and not INFER_ON_UNSLOTH:
        return "transformers", None
    if req.get("base_adapters"):
        return "transformers", "a model that continues an earlier run loads with the standard loader"
    if req.get("allow_pickle"):
        return "transformers", "pickle weights load with the standard loader"
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


def context_length(model_id, revision=None, trust_remote_code=False, fallback=32768):
    """The model's own context length. Unsloth sizes its attention caches to
    max_seq_length and refuses longer prompts, and answers over documents
    often pass 8,192 tokens."""
    try:
        from transformers import AutoConfig

        c = AutoConfig.from_pretrained(model_id, revision=revision, trust_remote_code=bool(trust_remote_code))
        c = getattr(c, "text_config", None) or c
        n = getattr(c, "max_position_embeddings", None)
        return int(n) if n else fallback
    except Exception:  # noqa: BLE001 - a guess is better than no model
        return fallback


def load_for_inference_unsloth(model_id, hw, adapter=None, revision=None, trust_remote_code=False, load_in_4bit=False,
                               max_seq_length=None):
    """A model (plus an optional LoRA adapter) ready for fast generation."""
    from unsloth import FastLanguageModel

    if max_seq_length is None:
        max_seq_length = context_length(model_id, revision, trust_remote_code)
    with contextlib.redirect_stdout(sys.stderr):      # keep stdout for the worker's JSON
        model, _ = FastLanguageModel.from_pretrained(
            model_name=model_id, revision=revision, max_seq_length=int(max_seq_length), dtype=hw.dtype,
            load_in_4bit=bool(load_in_4bit), trust_remote_code=bool(trust_remote_code), use_exact_model_name=True,
        )
        if adapter:
            from peft import PeftModel

            model = PeftModel.from_pretrained(model, str(adapter))
        FastLanguageModel.for_inference(model)
    model._dragonfarm_unsloth = True
    return model
