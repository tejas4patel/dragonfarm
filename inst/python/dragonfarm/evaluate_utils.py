"""Held-out loss and sample generations. Shared by train.py and evaluate.py."""

import gc
import json
import math

import torch
import torch.nn.functional as F

from .data import IGNORE_INDEX, PadCollator, render_prompt

# Positions scored per lm_head call. 256 positions x a 150k vocabulary in
# float32 is about 150 MB per row, against several GB for a whole sequence.
LOSS_CHUNK = 256


def _decoder_and_head(model):
    """The transformer body and the output projection, or (None, None).

    Scoring the hidden states chunk by chunk through lm_head avoids ever
    holding the full [batch, seq, vocab] logits tensor, which is what runs an
    8 GB GPU out of memory at long sequence lengths. Models with logit
    soft-capping (Gemma 2) apply it after lm_head, so they take the full path.
    """
    base = model.get_base_model() if hasattr(model, "get_base_model") else model
    cfg = getattr(base, "config", None)
    if getattr(cfg, "final_logit_softcapping", None):
        return None, None
    try:
        dec = base.get_decoder()
        head = base.get_output_embeddings()
    except Exception:
        return None, None
    if dec is None or head is None:
        return None, None
    return dec, head


@torch.no_grad()
def token_loss_sum(model, input_ids, attention_mask, labels, chunk=LOSS_CHUNK):
    """Summed cross-entropy over the labelled (assistant) tokens of a batch."""
    labels = labels[:, 1:]
    dec, head = _decoder_and_head(model)
    total = torch.zeros((), dtype=torch.float32, device=input_ids.device)
    if dec is not None:
        hidden = dec(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state[:, :-1]
        for s in range(0, hidden.size(1), chunk):
            lab = labels[:, s:s + chunk]
            if not bool((lab != IGNORE_INDEX).any()):
                continue
            logits = head(hidden[:, s:s + chunk]).float()
            total += F.cross_entropy(logits.reshape(-1, logits.size(-1)), lab.reshape(-1),
                                     ignore_index=IGNORE_INDEX, reduction="sum")
        return total
    logits_all = model(input_ids=input_ids, attention_mask=attention_mask).logits[:, :-1]
    for s in range(0, logits_all.size(1), chunk):
        logits = logits_all[:, s:s + chunk].float()
        total += F.cross_entropy(logits.reshape(-1, logits.size(-1)), labels[:, s:s + chunk].reshape(-1),
                                 ignore_index=IGNORE_INDEX, reduction="sum")
    return total


def chunked_loss_pays(model, input_ids, threshold_mb=None):
    """Use the chunked training loss only when the full float32 logits for this
    batch would be large (default 256 MB, DRAGONFARM_CHUNKED_LOSS_MB).

    Timed alone, the chunked loss costs about the same as the library's. Its
    trade-off is how memory sits on a nearly full card: on a 7B in 4-bit with
    short rows (about 180 MB of logits), always chunking pushed an 8 GB GPU
    into shared system memory and steps took 54 s instead of 13. With this
    threshold that run takes the library path (12.7 s a step), while document
    rows of about 1,000 tokens on a 0.5B (about 600 MB) take the chunked path
    (8 minutes for three epochs, 6.2 GB peak, where the library loss ran out
    of memory)."""
    import os

    if threshold_mb is None:
        threshold_mb = float(os.environ.get("DRAGONFARM_CHUNKED_LOSS_MB", 256))
    base = model.get_base_model() if hasattr(model, "get_base_model") else model
    vocab = getattr(getattr(base, "config", None), "vocab_size", None) or 0
    return input_ids.numel() * vocab * 4 / 2**20 >= threshold_mb


def chunked_train_loss(model, input_ids, attention_mask, labels, num_items_in_batch=None, chunk=LOSS_CHUNK):
    """Training loss computed through the output layer one chunk of positions
    at a time, with each chunk recomputed in the backward pass.

    A causal LM's own loss builds the full [batch, seq, vocab] logits and keeps
    them for the backward pass; with a 151k-token vocabulary at 1,536 tokens
    that is about a gigabyte per row in float32, which is what ran an 8 GB GPU
    out of memory on document prompts. Here only one chunk's logits exist at a
    time. The value and gradients match the model's own loss: summed
    cross-entropy over the labelled tokens, divided by num_items_in_batch when
    the trainer passes it (gradient accumulation), else by this batch's count.
    Returns None when the model cannot be split (the caller falls back)."""
    from torch.utils.checkpoint import checkpoint

    dec, head = _decoder_and_head(model)
    if dec is None:
        return None
    hidden = dec(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state[:, :-1]
    shifted = labels[:, 1:]

    def ce(h, lab):
        logits = head(h).float()
        return F.cross_entropy(logits.reshape(-1, logits.size(-1)), lab.reshape(-1),
                               ignore_index=IGNORE_INDEX, reduction="sum")

    total = hidden.new_zeros((), dtype=torch.float32)
    for s in range(0, hidden.size(1), chunk):
        lab = shifted[:, s:s + chunk]
        if not bool((lab != IGNORE_INDEX).any()):
            continue
        total = total + checkpoint(ce, hidden[:, s:s + chunk], lab, use_reentrant=False)
    if num_items_in_batch is not None:
        denom = num_items_in_batch
    else:
        denom = (shifted != IGNORE_INDEX).sum().clamp(min=1)
    if torch.is_tensor(denom):
        denom = denom.to(total.device)
    return total / denom


def free_gpu_memory():
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()


def is_oom(err):
    return isinstance(err, torch.cuda.OutOfMemoryError) or "out of memory" in str(err).lower()


@torch.no_grad()
def eval_loss(model, dataset, pad_token_id, device, batch_size=1):
    """Mean token-level cross-entropy over the assistant tokens.

    Falls back to one row at a time if a batch runs out of GPU memory.
    """
    collate = PadCollator(pad_token_id)
    total_loss, total_tokens = 0.0, 0
    model.eval()

    def score(rows):
        batch = collate(rows)
        batch = {k: v.to(device) for k, v in batch.items()}
        loss = token_loss_sum(model, batch["input_ids"], batch["attention_mask"], batch["labels"])
        n = int((batch["labels"][:, 1:] != IGNORE_INDEX).sum())
        return float(loss), n

    i = 0
    while i < len(dataset):
        rows = [dataset[j] for j in range(i, min(i + batch_size, len(dataset)))]
        try:
            loss, n = score(rows)
        except Exception as e:  # noqa: BLE001 - only OOM is handled, anything else is re-raised
            if not is_oom(e) or len(rows) == 1:
                raise
            print(f"[dragonfarm] evaluation batch of {len(rows)} ran out of memory; retrying one row at a time",
                  flush=True)
            free_gpu_memory()
            batch_size = 1
            continue
        total_loss += loss
        total_tokens += n
        i += len(rows)
    if total_tokens == 0:
        return None
    mean = total_loss / total_tokens
    return {"eval_loss": mean, "perplexity": math.exp(min(mean, 50)), "eval_tokens": total_tokens}


def evaluate_or_warn(status, label, fn):
    """Run an end-of-training evaluation; on GPU out-of-memory, record a warning instead of failing the run.

    By this point the adapter is saved and training has succeeded, so a run
    should not be marked failed because the GPU could not also fit the
    evaluation.
    """
    try:
        return fn()
    except Exception as e:  # noqa: BLE001
        if not is_oom(e):
            raise
        msg = (f"{label} skipped: the GPU ran out of memory after training finished. "
               "The adapter is saved. Lower max_seq_len or eval_batch_size, or run dragon_evaluate() on a freer GPU.")
        print(f"[dragonfarm] {msg}", flush=True)
        status.update(eval_warning=msg)
        free_gpu_memory()
        return None


@torch.no_grad()
def generate_reply(model, tok, messages, device, max_new_tokens=256, temperature=0.7, top_p=0.9, tools=None):
    text = render_prompt(tok, messages, tools)
    enc = tok(text, return_tensors="pt", add_special_tokens=False).to(device)
    kwargs = dict(max_new_tokens=max_new_tokens, pad_token_id=tok.pad_token_id)
    if temperature and temperature > 0:
        kwargs.update(do_sample=True, temperature=float(temperature), top_p=float(top_p))
    else:
        kwargs.update(do_sample=False)
    out = model.generate(**enc, **kwargs)
    new_tokens = out[0, enc["input_ids"].shape[1]:]
    return tok.decode(new_tokens, skip_special_tokens=True).strip()


def generate_replies(model, tok, conversations, device, max_new_tokens=256, temperature=0.7, top_p=0.9,
                     batch_size=8, tools=None):
    """Replies for several conversations, a batch at a time with left padding.

    One prompt at a time costs a full forward pass per token per prompt, which
    for a small model is dominated by per-step overhead: twenty short prompts
    took about ninety seconds on a 0.5B. Batched they take a few. A batch that
    runs out of GPU memory falls back to one prompt at a time."""
    if not conversations:
        return []
    if len(conversations) == 1 or batch_size <= 1:
        return [generate_reply(model, tok, m, device, max_new_tokens, temperature, top_p, tools) for m in conversations]
    kwargs = dict(max_new_tokens=max_new_tokens, pad_token_id=tok.pad_token_id)
    if temperature and temperature > 0:
        kwargs.update(do_sample=True, temperature=float(temperature), top_p=float(top_p))
    else:
        kwargs.update(do_sample=False)
    out = []
    for i in range(0, len(conversations), batch_size):
        batch = conversations[i:i + batch_size]
        texts = [render_prompt(tok, m, tools) for m in batch]
        side = tok.padding_side
        tok.padding_side = "left"
        try:
            enc = tok(texts, return_tensors="pt", padding=True, add_special_tokens=False).to(device)
            gen = model.generate(**enc, **kwargs)
        except Exception as e:
            if not is_oom(e):
                raise
            free_gpu_memory()
            out += [generate_reply(model, tok, m, device, max_new_tokens, temperature, top_p) for m in batch]
            continue
        finally:
            tok.padding_side = side
        start = enc["input_ids"].shape[1]
        out += [tok.decode(seq[start:], skip_special_tokens=True).strip() for seq in gen]
    return out


def sample_generations(model, tok, records, device, n=10, max_new_tokens=200):
    records = records[:n]
    prompts = [rec["messages"][:-1] for rec in records]
    generated = generate_replies(model, tok, prompts, device, max_new_tokens=max_new_tokens, temperature=0.0)
    samples = []
    for rec, prompt_msgs, text in zip(records, prompts, generated):
        user = next((m["content"] for m in prompt_msgs if m["role"] == "user"), "")
        samples.append({"prompt": user, "reference": rec["messages"][-1]["content"], "generated": text})
    return samples


def write_eval_files(run_dir, metrics, samples):
    with open(run_dir / "eval.json", "w", encoding="utf-8") as f:
        json.dump(metrics or {}, f, indent=2)
    with open(run_dir / "samples.json", "w", encoding="utf-8") as f:
        json.dump(samples, f, indent=2, ensure_ascii=False)
