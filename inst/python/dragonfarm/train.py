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

from .resume import checkpoint_step, latest_checkpoint, trim_progress
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


def resume_point(run_dir: Path, resume: bool):
    """The checkpoint to resume from, with progress rows after it dropped."""
    if not resume:
        return None
    ckpt = latest_checkpoint(run_dir)
    if ckpt is None:
        print("[dragonfarm] no checkpoint found, starting from scratch", flush=True)
        trim_progress(run_dir, 0)
        return None
    dropped = trim_progress(run_dir, checkpoint_step(ckpt))
    print(f"[dragonfarm] resuming from {ckpt.name}" + (f"; {dropped} progress rows after it are retrained" if dropped else ""),
          flush=True)
    return str(ckpt)


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
        allow_pickle=bool(m.get("allow_pickle", False)),
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
    resume_from = resume_point(run_dir, resume)
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
            from .backend import for_inference

            for_inference(model)
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
    resume_from = resume_point(run_dir, resume)
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

    # Chosen first: Unsloth has to be imported before transformers (D-35).
    from . import backend as be

    lib, why = be.choose(cfg, stage)
    status.update(backend=lib, backend_note=why)
    print(f"[dragonfarm] trainer: {lib}" + (f" ({why})" if why else ""), flush=True)

    from .callbacks import CancelFlag
    from .hardware import resolve
    from .loading import load_tokenizer

    cancel = CancelFlag(run_dir)
    hw = resolve(cfg.get("hardware"))
    status.update(device=hw.device_str, dtype=hw.dtype_name, device_name=hw.device_name, stage=stage)
    print(f"[dragonfarm] stage={stage} device={hw.device_str} dtype={hw.dtype_name} ({hw.device_name})", flush=True)

    if lib == "unsloth":
        # Unsloth's own fused loss in training; held-out scoring stays the
        # same chunked measure for both trainers.
        os.environ["DRAGONFARM_FULL_LOSS"] = "1"
        model, tok = be.load_policy_unsloth(cfg, hw, status)
    else:
        m = cfg["model"]
        tok = load_tokenizer(m["id"], m.get("revision"), m.get("trust_remote_code", False))
        model = load_policy(cfg, run_dir, hw, status)
    return STAGES[stage](cfg, run_dir, status, resume, hw, tok, model, cancel)


# One GPU per run, unless the person chose devices: on a machine with two
# (Kaggle's "T4 x2") the trainer would otherwise split every step across both
# and double the effective batch, so the same settings would train
# differently there than on a laptop. Set before torch starts CUDA.
def pin_one_gpu(env=os.environ):
    if "CUDA_VISIBLE_DEVICES" not in env:
        env["CUDA_VISIBLE_DEVICES"] = "0"


def main(argv=None):
    pin_one_gpu()
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--resume", action="store_true")
    a = ap.parse_args(argv)
    run_dir = Path(a.run_dir).resolve()
    status = Status(run_dir)
    status.update(state="running", pid=os.getpid(), started_at=now_iso(), finished_at=None, error=None)
    retried = False
    while True:
        try:
            result = train(run_dir, status, resume=a.resume)
            status.update(state=result, finished_at=now_iso())
            print(f"[dragonfarm] {result}", flush=True)
            sys.exit(0)
        except BaseException as e:  # noqa: BLE001 - we want SystemExit/KeyboardInterrupt too
            if isinstance(e, SystemExit) and e.code in (0, None):
                raise
            traceback.print_exc()
            change = None if retried or not recoverable_oom(e) else memory_safer(run_dir)
            if change is None:
                status.update(state="failed", finished_at=now_iso(), error=f"{type(e).__name__}: {e}" + memory_hint(e),
                              error_code=classify(e))
                sys.exit(1)
        # Out of memory once: train again with the safer settings (outside the
        # except block, so the failed attempt's model can be freed).
        retried = True
        free_gpu()
        status.update(memory_retry=change)
        print(f"[dragonfarm] out of GPU memory; training again with batch size {change['to']['per_device_batch_size']}, "
              f"gradient accumulation {change['to']['gradient_accumulation']}, gradient checkpointing on "
              "(the same effective batch)", flush=True)


# The first fixes for an out-of-memory start, applied once: batch size 1 with
# the accumulation raised to keep the same effective batch, and gradient
# checkpointing on. Written to config.json, so the run's record shows the
# settings it trained with. None when there is nothing left to lower.
def memory_safer(run_dir):
    path = Path(run_dir) / "config.json"
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    t = cfg["train"]
    before = {k: t.get(k) for k in ("per_device_batch_size", "gradient_accumulation", "gradient_checkpointing")}
    batch = int(t.get("per_device_batch_size") or 1)
    if batch <= 1 and t.get("gradient_checkpointing"):
        return None
    t["gradient_accumulation"] = int(t.get("gradient_accumulation") or 1) * batch
    t["per_device_batch_size"] = 1
    t["gradient_checkpointing"] = True
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    after = {k: t.get(k) for k in before}
    return {"from": before, "to": after}


# Only torch's own allocator error leaves the process usable. A driver-level
# CUDA error ("CUDA error: out of memory", sticky) poisons the CUDA context
# for the rest of the process: seen on a Windows laptop, where the retry then
# failed while loading the model. Those fail at once, settings unchanged.
def recoverable_oom(err):
    if classify(err) != "OUT_OF_MEMORY":
        return False
    text = f"{type(err).__name__}: {err}"
    return "OutOfMemoryError" in type(err).__name__ or "Tried to allocate" in text and "CUDA error" not in text


def free_gpu():
    import gc
    gc.collect()
    try:
        import torch
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
    except Exception:
        pass


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
