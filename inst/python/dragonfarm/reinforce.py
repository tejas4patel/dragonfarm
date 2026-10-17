"""Group Relative Policy Optimization (GRPO) with verifiable rewards.

For every prompt the policy samples a group of completions, each is scored
by the reward set, and the advantage of a completion is its reward's
z-score within its group. The update pushes up the log-probability of
completions that beat their group's mean and down those below it, with a
KL penalty against the reference model (the policy with its LoRA adapter
switched off) to keep the model from drifting.

One optimizer step per batch of freshly sampled completions keeps the
update on-policy, so the importance ratio is 1 and no clipping is needed.
This is the plain, stable form of GRPO; it fits small models and a single
GPU, which is what this package is for.
"""

import json
import math
import random
import time

import torch

from .callbacks import append_progress
from .resume import (checkpoint_step, latest_checkpoint, restore_reinforce_checkpoint,
                          save_reinforce_checkpoint, trim_progress)
from .data import IGNORE_INDEX, render_prompt
from .losses import token_logps
from .rewards import RewardSet


def read_prompt_records(path):
    records = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def user_text(msgs):
    for m in reversed(msgs):
        if m.get("role") == "user":
            return m.get("content", "")
    return ""


@torch.no_grad()
def sample_group(model, tok, msgs, device, group_size, temperature, max_new_tokens, top_p=1.0):
    """Sample ``group_size`` completions for one prompt. Returns (prompt_ids, [completion_ids], [texts])."""
    text = render_prompt(tok, msgs)
    enc = tok(text, return_tensors="pt", add_special_tokens=False).to(device)
    out = model.generate(
        **enc,
        do_sample=True,
        temperature=float(temperature),
        top_p=float(top_p),
        max_new_tokens=int(max_new_tokens),
        num_return_sequences=int(group_size),
        pad_token_id=tok.pad_token_id,
        use_cache=True,
    )
    n_prompt = enc["input_ids"].shape[1]
    prompt_ids = enc["input_ids"][0].tolist()
    completions, texts = [], []
    for row in out:
        ids = row[n_prompt:].tolist()
        # Cut at the first EOS (keep it so the model learns to stop) and drop padding.
        cut = []
        for t in ids:
            cut.append(t)
            if t == tok.eos_token_id:
                break
        while cut and cut[-1] == tok.pad_token_id and cut[-1] != tok.eos_token_id:
            cut.pop()
        completions.append(cut)
        texts.append(tok.decode(cut, skip_special_tokens=True).strip())
    return prompt_ids, completions, texts


def build_batch(prompt_ids, completions, pad_id, device):
    """Right-padded input_ids, attention_mask, and labels (prompt masked)."""
    seqs = [prompt_ids + c for c in completions]
    width = max(len(s) for s in seqs)
    ids, mask, labels = [], [], []
    for s, c in zip(seqs, completions):
        n = len(s)
        ids.append(s + [pad_id] * (width - n))
        mask.append([1] * n + [0] * (width - n))
        labels.append([IGNORE_INDEX] * len(prompt_ids) + c + [IGNORE_INDEX] * (width - n))
    return (
        torch.tensor(ids, dtype=torch.long, device=device),
        torch.tensor(mask, dtype=torch.long, device=device),
        torch.tensor(labels, dtype=torch.long, device=device),
    )


def group_advantages(rewards):
    r = torch.tensor(rewards, dtype=torch.float32)
    if r.numel() < 2 or float(r.std()) < 1e-6:
        return torch.zeros_like(r)
    return (r - r.mean()) / (r.std() + 1e-4)


def grpo_loss(policy_logps, ref_logps, mask, advantages, beta):
    """Per-token GRPO objective averaged over completion tokens.

    ``policy_logps``/``ref_logps``/``mask`` are (batch, tokens); ``advantages``
    is (batch,). Returns (loss, mean_kl).
    """
    diff = ref_logps - policy_logps
    kl = torch.exp(diff) - diff - 1.0            # k3 estimator, always >= 0
    per_token = -(advantages.unsqueeze(1) * policy_logps) + beta * kl
    denom = mask.sum().clamp(min=1)
    loss = (per_token * mask).sum() / denom
    mean_kl = float((kl.detach() * mask).sum() / denom)
    return loss, mean_kl


def run_reinforce(cfg, run_dir, status, resume, hw, tok, model, cancel):
    rl = cfg.get("reinforce") or {}
    t = cfg["train"]
    group_size = int(rl.get("group_size", 4))
    beta = float(rl.get("beta", 0.04))
    temperature = float(rl.get("temperature", 1.0))
    max_new_tokens = int(rl.get("max_new_tokens", 128))
    micro = int(rl.get("micro_batch", 4))
    rewards = RewardSet(rl.get("rewards") or [], run_dir=run_dir)

    records = read_prompt_records(run_dir / cfg["data"]["train"])
    if not records:
        raise RuntimeError("no prompts to train on")
    eval_records = read_prompt_records(run_dir / cfg["data"]["eval"]) if cfg["data"].get("eval") else []

    batch_prompts = int(t["per_device_batch_size"])
    steps_per_epoch = max(1, math.ceil(len(records) / batch_prompts))
    total_steps = int(t["max_steps"]) if t.get("max_steps") else int(math.ceil(float(t["epochs"]) * steps_per_epoch))
    status.update(total_steps=total_steps, reward_names=rewards.names)

    params = [p for p in model.parameters() if p.requires_grad]
    optimizer = torch.optim.AdamW(params, lr=float(t["learning_rate"]), weight_decay=float(t.get("weight_decay", 0.0)))
    warmup = int(round(float(t.get("warmup_ratio", 0.03)) * total_steps))

    def lr_at(step):
        if warmup and step < warmup:
            return (step + 1) / warmup
        progress = (step - warmup) / max(1, total_steps - warmup)
        return 0.5 * (1.0 + math.cos(math.pi * min(1.0, progress)))

    scheduler = torch.optim.lr_scheduler.LambdaLR(optimizer, lr_at)

    start_step = 0
    if resume:
        ckpt = latest_checkpoint(run_dir)
        if ckpt is None:
            print("[dragonfarm] no checkpoint found, starting from scratch", flush=True)
            trim_progress(run_dir, 0)
        else:
            start_step = checkpoint_step(ckpt)
            with_optimizer = restore_reinforce_checkpoint(model, optimizer, ckpt)
            trim_progress(run_dir, start_step)
            for _ in range(start_step):
                scheduler.step()
            print(f"[dragonfarm] resuming at step {start_step} from {ckpt.name} (adapter weights"
                  + (" and optimizer" if with_optimizer else "") + " restored)", flush=True)

    rng = random.Random(int(t.get("seed", 42)))
    order = list(range(len(records)))
    rng.shuffle(order)
    cursor = (start_step * batch_prompts) % len(order)
    t0 = time.time()
    print(f"[dragonfarm] GRPO: {len(records)} prompts, group {group_size}, beta {beta}, "
          f"{total_steps} steps, rewards {rewards.names}", flush=True)

    unwrapped = model
    step = start_step
    while step < total_steps:
        batch = []
        for _ in range(batch_prompts):
            if cursor >= len(order):
                rng.shuffle(order)
                cursor = 0
            batch.append(records[order[cursor]])
            cursor += 1

        # 1. Sample a group per prompt and score it.
        model.eval()
        groups = []
        for rec in batch:
            prompt_ids, comps, texts = sample_group(model, tok, rec["prompt"], hw.device, group_size, temperature, max_new_tokens)
            totals, parts = rewards.score_many(
                [user_text(rec["prompt"])] * len(texts), texts,
                [rec.get("reference")] * len(texts), [rec.get("fields") or {}] * len(texts),
            )
            groups.append((prompt_ids, comps, texts, totals, parts))

        # 2. Advantages within each group; flatten to a batch of sequences.
        seq_prompt, seq_comp, seq_adv, all_rewards, all_len = [], [], [], [], []
        breakdown = {name: [] for name in rewards.names}
        for prompt_ids, comps, texts, totals, parts in groups:
            adv = group_advantages(totals)
            for c, a, r in zip(comps, adv.tolist(), totals):
                if len(c) == 0:
                    continue
                seq_prompt.append(prompt_ids)
                seq_comp.append(c)
                seq_adv.append(a)
                all_rewards.append(r)
                all_len.append(len(c))
            for name in rewards.names:
                breakdown[name].extend(parts[name])

        # 3. Policy gradient step over micro-batches of sequences.
        model.train()
        optimizer.zero_grad(set_to_none=True)
        total_tokens = 0
        loss_sum, kl_sum = 0.0, 0.0
        useful = [i for i, a in enumerate(seq_adv) if abs(a) > 1e-8]
        if useful:
            for i in range(0, len(useful), micro):
                idx = useful[i:i + micro]
                # sequences in a micro-batch may have different prompts; pad each on its own
                ids_list, mask_list, lab_list = [], [], []
                width = max(len(seq_prompt[j]) + len(seq_comp[j]) for j in idx)
                for j in idx:
                    s = seq_prompt[j] + seq_comp[j]
                    n = len(s)
                    ids_list.append(s + [tok.pad_token_id] * (width - n))
                    mask_list.append([1] * n + [0] * (width - n))
                    lab_list.append([IGNORE_INDEX] * len(seq_prompt[j]) + seq_comp[j] + [IGNORE_INDEX] * (width - n))
                ids = torch.tensor(ids_list, dtype=torch.long, device=hw.device)
                mask = torch.tensor(mask_list, dtype=torch.long, device=hw.device)
                labels = torch.tensor(lab_list, dtype=torch.long, device=hw.device)
                adv = torch.tensor([seq_adv[j] for j in idx], dtype=torch.float32, device=hw.device)

                out = model(input_ids=ids, attention_mask=mask)
                pol, tok_mask = token_logps(out.logits, labels)
                with torch.no_grad():
                    with unwrapped.disable_adapter():
                        ref_out = model(input_ids=ids, attention_mask=mask)
                    ref, _ = token_logps(ref_out.logits, labels)
                loss, kl = grpo_loss(pol, ref, tok_mask, adv, beta)
                n_tok = int(tok_mask.sum())
                # weight each micro-batch by its token count so the step equals one big batch
                (loss * n_tok).backward()
                loss_sum += float(loss) * n_tok
                kl_sum += kl * n_tok
                total_tokens += n_tok
                del out, ref_out, pol, ref
            for p in params:
                if p.grad is not None:
                    p.grad.div_(max(1, total_tokens))
            torch.nn.utils.clip_grad_norm_(params, 1.0)
            optimizer.step()
        scheduler.step()
        step += 1

        elapsed = time.time() - t0
        row = {
            "step": step,
            "epoch": round(step / steps_per_epoch, 4),
            "elapsed_s": round(elapsed, 1),
            "eta_s": round(elapsed / max(1, step - start_step) * (total_steps - step), 1),
            "loss": (loss_sum / total_tokens) if total_tokens else 0.0,
            "kl": (kl_sum / total_tokens) if total_tokens else 0.0,
            "reward": float(sum(all_rewards) / len(all_rewards)) if all_rewards else 0.0,
            "reward_std": float(torch.tensor(all_rewards).std()) if len(all_rewards) > 1 else 0.0,
            "completion_len": float(sum(all_len) / len(all_len)) if all_len else 0.0,
            "lr": float(scheduler.get_last_lr()[0]),
        }
        for name, vals in breakdown.items():
            if vals:
                row[f"reward_{name}"] = float(sum(vals) / len(vals))
        append_progress(run_dir, row)
        print(json.dumps({k: (round(v, 4) if isinstance(v, float) else v) for k, v in row.items()}), flush=True)

        if step % int(t["save_steps"]) == 0 or step == total_steps or cancel.check():
            save_reinforce_checkpoint(model, optimizer, run_dir, step)
            status.update(latest_checkpoint=f"checkpoints/checkpoint-{step}")
        if cancel.check():
            print("[dragonfarm] cancel requested; stopping after this step", flush=True)
            break

    return rewards, eval_records


@torch.no_grad()
def eval_reinforce(model, tok, rewards, records, device, max_new_tokens, n_samples):
    """Greedy completions on held-out prompts, scored by the same rewards."""
    if not records:
        return None, []
    model.eval()
    totals, breakdown, samples = [], {name: [] for name in rewards.names}, []
    for i, rec in enumerate(records):
        text = render_prompt(tok, rec["prompt"])
        enc = tok(text, return_tensors="pt", add_special_tokens=False).to(device)
        out = model.generate(**enc, do_sample=False, max_new_tokens=int(max_new_tokens), pad_token_id=tok.pad_token_id, use_cache=True)
        completion = tok.decode(out[0, enc["input_ids"].shape[1]:], skip_special_tokens=True).strip()
        total, parts = rewards.score(user_text(rec["prompt"]), completion, rec.get("reference"), rec.get("fields") or {})
        totals.append(total)
        for name in rewards.names:
            breakdown[name].append(parts[name])
        if i < n_samples:
            samples.append({"prompt": user_text(rec["prompt"]), "reference": rec.get("reference"),
                            "generated": completion, "reward": total})
    metrics = {
        "reward_mean": sum(totals) / len(totals),
        "reward_breakdown": {name: sum(v) / len(v) for name, v in breakdown.items()},
        "eval_prompts": len(totals),
    }
    return metrics, samples
