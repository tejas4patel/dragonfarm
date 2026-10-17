"""Entry point: python -m dragonfarm.train --run-dir <dir> [--resume]

Runs one stage of post-training, chosen by config.json's ``stage``:

* ``sft``       supervised fine-tuning on prompt/response rows
* ``prefer``    preference optimization (DPO or ORPO) on chosen/rejected pairs
* ``reinforce`` GRPO with verifiable rewards on prompt rows

Earlier stages chain through ``model.base_adapters``: those adapters are
folded into the base weights before this stage's LoRA is added.
"""

import argparse
import json
import os
import signal
import sys
import traceback
from pathlib import Path

from .errors import classify
from .status import Status, now_iso

# Installed before torch is imported. A console Ctrl+C reaching this process
# while it is still loading would otherwise kill it silently. When R manages
# the run (DRAGONFARM_MANAGED=1) cancellation goes through cancel.request, so
# console signals are logged and ignored for the whole run; see callbacks.py.
_MANAGED = os.environ.get("DRAGONFARM_MANAGED") == "1"


def _startup_signal(signum, frame):
    print(f"[dragonfarm] received signal {signum} during startup; ignoring", flush=True)


for _sig in (signal.SIGINT, signal.SIGTERM):
    try:
        signal.signal(_sig, _startup_signal)
    except (ValueError, OSError):
        pass


def latest_checkpoint(run_dir: Path):
    ck = run_dir / "checkpoints"
    if not ck.exists():
        return None
    cands = [p for p in ck.iterdir() if p.is_dir() and p.name.startswith("checkpoint-")]
    if not cands:
        return None
    return max(cands, key=lambda p: int(p.name.split("-")[-1]))


def eval_batch_size(cfg):
    """Rows per evaluation forward pass. Defaults to 1: evaluation materializes
    [batch, seq, vocab] logits, which at long sequence lengths is what pushes
    an 8 GB GPU over the edge after training itself has succeeded."""
    return max(1, int(cfg["train"].get("per_device_eval_batch_size") or 1))


def release_trainer(trainer):
    """Drop the trainer's optimizer state and cached activations before the
    end-of-run evaluation so the evaluation gets the whole GPU."""
    from .evaluate_utils import free_gpu_memory

    for attr in ("optimizer", "lr_scheduler"):
        if hasattr(trainer, attr):
            setattr(trainer, attr, None)
    del trainer
    free_gpu_memory()


def training_arguments(cfg, run_dir, hw, has_eval):
    """TrainingArguments shared by every stage."""
    import inspect

    from transformers import TrainingArguments

    t = cfg["train"]
    extra = dict(t.get("extra") or {})
    ta_params = set(inspect.signature(TrainingArguments.__init__).parameters)
    warmup_ratio = float(t.get("warmup_ratio", 0.03))
    if "warmup_ratio" in ta_params:
        warmup_kwargs = {"warmup_ratio": warmup_ratio}
    else:
        # transformers >= 5: warmup_steps takes a fraction when below 1.
        warmup_kwargs = {"warmup_steps": warmup_ratio}
    kwargs = dict(
        output_dir=str(run_dir / "checkpoints"),
        num_train_epochs=float(t["epochs"]),
        max_steps=int(t["max_steps"]) if t.get("max_steps") else -1,
        learning_rate=float(t["learning_rate"]),
        per_device_train_batch_size=int(t["per_device_batch_size"]),
        per_device_eval_batch_size=eval_batch_size(cfg),
        gradient_accumulation_steps=int(t["gradient_accumulation"]),
        weight_decay=float(t.get("weight_decay", 0.0)),
        lr_scheduler_type="cosine",
        logging_steps=int(t["logging_steps"]),
        logging_first_step=True,
        save_strategy="steps",
        save_steps=int(t["save_steps"]),
        save_total_limit=2,
        eval_strategy="epoch" if has_eval else "no",
        bf16=hw.bf16,
        fp16=hw.fp16,
        seed=int(t.get("seed", 42)),
        report_to=[],
        disable_tqdm=True,
        remove_unused_columns=False,
        dataloader_pin_memory=(hw.kind == "cuda"),
        use_cpu=(hw.kind == "cpu"),
        gradient_checkpointing=bool(t.get("gradient_checkpointing", False)),
    )
    kwargs.update(warmup_kwargs)
    kwargs.update(extra)
    unknown = [k for k in kwargs if k not in ta_params]
    if unknown:
        raise TypeError(f"TrainingArguments does not accept {unknown} in this transformers version")
    return TrainingArguments(**kwargs)


def load_policy(cfg, run_dir, hw, status):
    """Base model, with earlier-stage adapters folded in, plus a fresh LoRA."""
    import torch
    from peft import LoraConfig, get_peft_model

    from .loading import apply_base_adapters, load_base_model

    m = cfg["model"]
    load_4bit = cfg["hardware"].get("load_in_4bit", False)
    base_adapters = [run_dir / p for p in (m.get("base_adapters") or [])]
    if base_adapters and load_4bit:
        raise RuntimeError("chaining from a previous run is not supported with load_in_4bit")

    print(f"[dragonfarm] loading {m['id']}", flush=True)
    model = load_base_model(
        m["id"], hw, revision=m.get("revision"),
        trust_remote_code=m.get("trust_remote_code", False), load_in_4bit=load_4bit,
    )
    if base_adapters:
        print(f"[dragonfarm] folding in {len(base_adapters)} earlier adapter(s) from {m.get('base_run')}", flush=True)
        model = apply_base_adapters(model, base_adapters)

    t = cfg["train"]
    if load_4bit:
        from peft import prepare_model_for_kbit_training

        model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=t.get("gradient_checkpointing", False))
    elif t.get("gradient_checkpointing", False):
        model.gradient_checkpointing_enable()
        model.enable_input_require_grads()

    lo = cfg["lora"]
    targets = lo.get("target_modules", "auto")
    lora_cfg = LoraConfig(
        r=int(lo["r"]),
        lora_alpha=float(lo["alpha"]),
        lora_dropout=float(lo["dropout"]),
        target_modules="all-linear" if targets == "auto" else list(targets),
        bias="none",
        task_type="CAUSAL_LM",
    )
    model = get_peft_model(model, lora_cfg)
    # Keep trainable weights in fp32 so fp16/bf16 autocast can scale gradients.
    for p in model.parameters():
        if p.requires_grad and p.dtype != torch.float32:
            p.data = p.data.float()
    trainable, total = model.get_nb_trainable_parameters()
    status.update(trainable_params=int(trainable), total_params=int(total))
    print(f"[dragonfarm] trainable params {trainable:,} of {total:,}", flush=True)
    return model


def make_trainer(cls, model, tok, targs, train_ds, eval_ds, collator, callbacks, **extra):
    kwargs = dict(model=model, args=targs, train_dataset=train_ds, eval_dataset=eval_ds,
                  data_collator=collator, callbacks=callbacks, **extra)
    try:
        return cls(processing_class=tok, **kwargs)
    except TypeError:
        return cls(tokenizer=tok, **kwargs)


def finish(model, tok, run_dir, cancel):
    adapter_dir = run_dir / "adapter"
    model.save_pretrained(str(adapter_dir))
    tok.save_pretrained(str(adapter_dir))
    print(f"[dragonfarm] adapter saved to {adapter_dir}", flush=True)
    return not cancel.check()


def make_sft_trainer_class():
    """A Trainer whose evaluation scores held-out rows with the chunked loss.

    Trainer's own prediction step runs the model with labels and lets the
    model build the full [batch, seq, vocab] float32 logits for the loss. At a
    long max_seq_len that single tensor is several gigabytes, and the
    end-of-epoch evaluation would fail a run whose training steps all fit.
    """
    import torch
    from transformers import Trainer

    from .data import IGNORE_INDEX
    from .evaluate_utils import chunked_loss_pays, chunked_train_loss, token_loss_sum

    class SftTrainer(Trainer):
        def compute_loss(self, model, inputs, return_outputs=False, num_items_in_batch=None):
            # The chunked loss keeps the [batch, seq, vocab] logits from ever
            # existing at once. Anything unusual takes the library's own path.
            if (return_outputs or self.label_smoother is not None or self.compute_loss_func is not None
                    or "labels" not in inputs or os.environ.get("DRAGONFARM_FULL_LOSS")
                    or not chunked_loss_pays(self.accelerator.unwrap_model(model), inputs["input_ids"])):
                return super().compute_loss(model, inputs, return_outputs, num_items_in_batch)
            n = num_items_in_batch if (self.model_accepts_loss_kwargs and num_items_in_batch is not None) else None
            loss = chunked_train_loss(self.accelerator.unwrap_model(model), inputs["input_ids"],
                                      inputs.get("attention_mask"), inputs["labels"], num_items_in_batch=n)
            if loss is None:
                return super().compute_loss(model, inputs, return_outputs, num_items_in_batch)
            return loss

        def prediction_step(self, model, inputs, prediction_loss_only, ignore_keys=None):
            inputs = self._prepare_inputs(inputs)
            unwrapped = self.accelerator.unwrap_model(model)
            unwrapped.eval()
            with torch.no_grad():
                labels = inputs["labels"]
                loss_sum = token_loss_sum(unwrapped, inputs["input_ids"], inputs["attention_mask"], labels)
                n = (labels[:, 1:] != IGNORE_INDEX).sum().clamp(min=1)
                loss = loss_sum / n
            return loss.detach(), None, None

    return SftTrainer


def run_sft(cfg, run_dir, status, resume, hw, tok, model, cancel):
    Trainer = make_sft_trainer_class()

    from .callbacks import ProgressCallback
    from .data import PadCollator, load_split
    from .evaluate_utils import eval_loss, evaluate_or_warn, sample_generations, write_eval_files

    max_len = int(cfg["train"]["max_seq_len"])
    train_ds, _ = load_split(run_dir / cfg["data"]["train"], tok, max_len)
    if len(train_ds) == 0:
        raise RuntimeError("no trainable examples after tokenization; check the column mapping and max_seq_len")
    if train_ds.skipped:
        print(f"[dragonfarm] skipped {train_ds.skipped} example(s) whose response was truncated away", flush=True)
    eval_ds, eval_records = (None, [])
    if cfg["data"].get("eval"):
        eval_ds, eval_records = load_split(run_dir / cfg["data"]["eval"], tok, max_len)
        if len(eval_ds) == 0:
            eval_ds = None

    targs = training_arguments(cfg, run_dir, hw, eval_ds is not None)
    trainer = make_trainer(Trainer, model, tok, targs, train_ds, eval_ds, PadCollator(tok.pad_token_id),
                           [ProgressCallback(run_dir, status, cancel)])
    resume_from = str(latest_checkpoint(run_dir)) if resume else None
    if resume and resume_from is None:
        print("[dragonfarm] no checkpoint found, starting from scratch", flush=True)
    print(f"[dragonfarm] training {len(train_ds)} examples"
          + (f", evaluating on {len(eval_ds)}" if eval_ds is not None else ""), flush=True)
    trainer.train(resume_from_checkpoint=resume_from)

    if not finish(model, tok, run_dir, cancel):
        return "cancelled"
    release_trainer(trainer)

    metrics, samples = None, []
    if eval_ds is not None:
        print("[dragonfarm] evaluating", flush=True)
        metrics = evaluate_or_warn(status, "Held-out evaluation", lambda: eval_loss(
            model, eval_ds, tok.pad_token_id, hw.device, batch_size=eval_batch_size(cfg)))
        n = int(cfg.get("eval", {}).get("n_samples", 10))
        if n > 0:
            samples = evaluate_or_warn(status, "Sample generation", lambda: sample_generations(
                model, tok, eval_records, hw.device, n=n)) or []
    write_eval_files(run_dir, metrics, samples)
    if metrics:
        status.update(eval_loss=metrics["eval_loss"], perplexity=metrics["perplexity"])
    return "succeeded"


def run_prefer(cfg, run_dir, status, resume, hw, tok, model, cancel):
    from .callbacks import ProgressCallback
    from .data import PairCollator, load_pairs_split
    from .evaluate_utils import evaluate_or_warn, write_eval_files
    from .prefer import PreferenceTrainer, eval_pairs, sample_pair_generations

    pref = cfg.get("prefer") or {}
    method = pref.get("method", "dpo")
    beta = float(pref.get("beta", 0.1))
    max_len = int(cfg["train"]["max_seq_len"])

    train_ds, _ = load_pairs_split(run_dir / cfg["data"]["train"], tok, max_len)
    if len(train_ds) == 0:
        raise RuntimeError("no trainable pairs after tokenization; check the column mapping and max_seq_len")
    if train_ds.skipped:
        print(f"[dragonfarm] skipped {train_ds.skipped} pair(s) whose responses were truncated away", flush=True)
    eval_ds, eval_records = (None, [])
    if cfg["data"].get("eval"):
        eval_ds, eval_records = load_pairs_split(run_dir / cfg["data"]["eval"], tok, max_len)
        if len(eval_ds) == 0:
            eval_ds = None

    targs = training_arguments(cfg, run_dir, hw, eval_ds is not None)
    trainer = make_trainer(PreferenceTrainer, model, tok, targs, train_ds, eval_ds, PairCollator(tok.pad_token_id),
                           [ProgressCallback(run_dir, status, cancel)],
                           method=method, beta=beta, pad_id=tok.pad_token_id)
    resume_from = str(latest_checkpoint(run_dir)) if resume else None
    if resume and resume_from is None:
        print("[dragonfarm] no checkpoint found, starting from scratch", flush=True)
    print(f"[dragonfarm] {method} (beta={beta}) on {len(train_ds)} pairs"
          + (f", evaluating on {len(eval_ds)}" if eval_ds is not None else ""), flush=True)
    trainer.train(resume_from_checkpoint=resume_from)

    if not finish(model, tok, run_dir, cancel):
        return "cancelled"
    release_trainer(trainer)

    metrics, samples = None, []
    if eval_ds is not None:
        print("[dragonfarm] evaluating", flush=True)
        metrics = evaluate_or_warn(status, "Held-out evaluation", lambda: eval_pairs(
            model, eval_ds, tok.pad_token_id, hw.device, method, beta, batch_size=eval_batch_size(cfg)))
        n = int(cfg.get("eval", {}).get("n_samples", 10))
        if n > 0:
            samples = evaluate_or_warn(status, "Sample generation", lambda: sample_pair_generations(
                model, tok, eval_records, hw.device, n=n)) or []
    write_eval_files(run_dir, metrics, samples)
    if metrics:
        status.update(eval_loss=metrics["eval_loss"], pref_accuracy=metrics["pref_accuracy"],
                      reward_margin=metrics["reward_margin"])
    return "succeeded"


def run_reinforce_stage(cfg, run_dir, status, resume, hw, tok, model, cancel):
    from .evaluate_utils import write_eval_files
    from .reinforce import eval_reinforce, run_reinforce

    rewards, eval_records = run_reinforce(cfg, run_dir, status, resume, hw, tok, model, cancel)
    if not finish(model, tok, run_dir, cancel):
        return "cancelled"
    rl = cfg.get("reinforce") or {}
    metrics, samples = None, []
    if eval_records:
        print("[dragonfarm] evaluating", flush=True)
        n = int(cfg.get("eval", {}).get("n_samples", 10))
        metrics, samples = eval_reinforce(model, tok, rewards, eval_records, hw.device,
                                          int(rl.get("max_new_tokens", 128)), n)
    write_eval_files(run_dir, metrics, samples)
    if metrics:
        status.update(reward_mean=metrics["reward_mean"], reward_breakdown=metrics["reward_breakdown"])
    return "succeeded"


STAGES = {"sft": run_sft, "prefer": run_prefer, "reinforce": run_reinforce_stage}


def train(run_dir: Path, status: Status, resume: bool) -> str:
    with open(run_dir / "config.json", encoding="utf-8") as f:
        cfg = json.load(f)
    stage = cfg.get("stage", "sft")
    if stage not in STAGES:
        raise RuntimeError(f"unknown stage {stage!r}; this trainer knows {sorted(STAGES)}")

    from .callbacks import CancelFlag
    from .hardware import resolve
    from .loading import load_tokenizer

    cancel = CancelFlag(run_dir)
    hw = resolve(cfg.get("hardware"))
    status.update(device=hw.device_str, dtype=hw.dtype_name, device_name=hw.device_name, stage=stage)
    print(f"[dragonfarm] stage={stage} device={hw.device_str} dtype={hw.dtype_name} ({hw.device_name})", flush=True)

    m = cfg["model"]
    tok = load_tokenizer(m["id"], m.get("revision"), m.get("trust_remote_code", False))
    model = load_policy(cfg, run_dir, hw, status)
    return STAGES[stage](cfg, run_dir, status, resume, hw, tok, model, cancel)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--resume", action="store_true")
    a = ap.parse_args(argv)
    run_dir = Path(a.run_dir).resolve()
    status = Status(run_dir)
    status.update(state="running", pid=os.getpid(), started_at=now_iso(), finished_at=None, error=None)
    try:
        result = train(run_dir, status, resume=a.resume)
        status.update(state=result, finished_at=now_iso())
        print(f"[dragonfarm] {result}", flush=True)
        sys.exit(0)
    except BaseException as e:  # noqa: BLE001 - we want SystemExit/KeyboardInterrupt too
        if isinstance(e, SystemExit) and e.code in (0, None):
            raise
        traceback.print_exc()
        status.update(state="failed", finished_at=now_iso(), error=f"{type(e).__name__}: {e}" + memory_hint(e),
                      error_code=classify(e))
        sys.exit(1)


# The usual fixes, named in the status file whatever form the out-of-memory
# error takes (see errors.MEMORY_SIGNS), so the log alone is enough to act on.
def memory_hint(err):
    if classify(err) != "OUT_OF_MEMORY":
        return ""
    return ("\nThis usually means the GPU ran out of memory. Try batch size 1 with gradient accumulation"
            " raised to keep the same effective batch, turn on gradient checkpointing, shorten the maximum"
            " sequence length, or load the model in 4-bit.")


if __name__ == "__main__":
    main()
