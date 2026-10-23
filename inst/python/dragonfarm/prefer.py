"""Preference optimization (DPO and ORPO) on top of the Hugging Face Trainer.

The Trainer supplies scheduling, checkpoints, resume, and callbacks; this
module supplies the loss. Chosen and rejected sequences are padded to one
width and run through the model as a single batch. For DPO the reference
log-probs come from the same model with its LoRA adapter switched off, so
no second copy of the weights is needed.
"""

from collections import defaultdict

import torch
import torch.nn.functional as F
from transformers import Trainer

from .data import IGNORE_INDEX, PairCollator
from .evaluate_utils import generate_reply
from .losses import dpo_loss, orpo_loss, sequence_logps


def concat_pairs(inputs, pad_id):
    """Stack chosen then rejected sequences into one batch of equal width."""
    c_ids, r_ids = inputs["chosen_input_ids"], inputs["rejected_input_ids"]
    width = max(c_ids.shape[1], r_ids.shape[1])

    def pad(t, value):
        return F.pad(t, (0, width - t.shape[1]), value=value)

    ids = torch.cat([pad(c_ids, pad_id), pad(r_ids, pad_id)])
    mask = torch.cat([pad(inputs["chosen_attention_mask"], 0), pad(inputs["rejected_attention_mask"], 0)])
    labels = torch.cat([pad(inputs["chosen_labels"], IGNORE_INDEX), pad(inputs["rejected_labels"], IGNORE_INDEX)])
    return ids, mask, labels


def _forward_logps(model, ids, mask, labels):
    out = model(input_ids=ids, attention_mask=mask)
    return sequence_logps(out.logits, labels)


def preference_loss(model, unwrapped, inputs, pad_id, method, beta):
    """Loss plus (accuracy, margin) for one batch of pairs."""
    ids, mask, labels = concat_pairs(inputs, pad_id)
    n = ids.shape[0] // 2
    logps, lens = _forward_logps(model, ids, mask, labels)
    pc, pr = logps[:n], logps[n:]
    if method == "dpo":
        with torch.no_grad():
            with unwrapped.disable_adapter():
                ref, _ = _forward_logps(model, ids, mask, labels)
        loss, cr, rr = dpo_loss(pc, pr, ref[:n], ref[n:], beta)
        acc = (cr > rr).float().mean()
        margin = (cr - rr).mean()
    elif method == "orpo":
        loss, log_odds, lc, lr = orpo_loss(pc, pr, lens[:n], lens[n:], beta)
        acc = (lc > lr).float().mean()
        margin = log_odds.mean()
    else:
        raise ValueError(f"unknown preference method {method!r}")
    return loss, float(acc), float(margin), n


class PreferenceTrainer(Trainer):
    def __init__(self, *args, method="dpo", beta=0.1, pad_id=0, **kwargs):
        super().__init__(*args, **kwargs)
        self.method = method
        self.beta = float(beta)
        self.pad_id = pad_id
        self._metrics = {"train": defaultdict(list), "eval": defaultdict(list)}

    def compute_loss(self, model, inputs, return_outputs=False, num_items_in_batch=None):
        unwrapped = self.accelerator.unwrap_model(model)
        loss, acc, margin, _ = preference_loss(model, unwrapped, inputs, self.pad_id, self.method, self.beta)
        split = "train" if model.training else "eval"
        self._metrics[split]["pref_acc"].append(acc)
        self._metrics[split]["reward_margin"].append(margin)
        return (loss, None) if return_outputs else loss

    def prediction_step(self, model, inputs, prediction_loss_only, ignore_keys=None):
        inputs = self._prepare_inputs(inputs)
        with torch.no_grad():
            loss = self.compute_loss(model, inputs)
        return loss.detach(), None, None

    def log(self, logs, *args, **kwargs):
        split = "eval" if any(k.startswith("eval_") for k in logs) else "train"
        prefix = "eval_" if split == "eval" else ""
        for key, values in self._metrics[split].items():
            if values:
                logs[prefix + key] = sum(values) / len(values)
        self._metrics[split].clear()
        return super().log(logs, *args, **kwargs)


@torch.no_grad()
def eval_pairs(model, dataset, pad_id, device, method, beta, batch_size=4):
    """Loss, preference accuracy, and reward margin over held-out pairs."""
    if len(dataset) == 0:
        return None
    collate = PairCollator(pad_id)
    unwrapped = model
    model.eval()
    tot_loss, tot_acc, tot_margin, tot_n = 0.0, 0.0, 0.0, 0
    for i in range(0, len(dataset), batch_size):
        batch = collate([dataset[j] for j in range(i, min(i + batch_size, len(dataset)))])
        batch = {k: v.to(device) for k, v in batch.items()}
        loss, acc, margin, n = preference_loss(model, unwrapped, batch, pad_id, method, beta)
        tot_loss += float(loss) * n
        tot_acc += acc * n
        tot_margin += margin * n
        tot_n += n
    return {
        "eval_loss": tot_loss / tot_n,
        "pref_accuracy": tot_acc / tot_n,
        "reward_margin": tot_margin / tot_n,
        "eval_pairs": tot_n,
        "method": method,
        "beta": beta,
    }


def sample_pair_generations(model, tok, records, device, n=10, max_new_tokens=200):
    from .evaluate_utils import fits_limit

    samples = []
    fitting = [rec for rec in records if fits_limit(model, tok, rec["prompt"], max_new_tokens)]
    if len(fitting) < len(records):
        print(f"[dragonfarm] {len(records) - len(fitting)} held-out prompt(s) longer than the model's sequence limit left out of the samples", flush=True)
    for rec in fitting[:n]:
        prompt_msgs = rec["prompt"]
        user = next((m["content"] for m in prompt_msgs if m["role"] == "user"), "")
        generated = generate_reply(model, tok, prompt_msgs, device, max_new_tokens=max_new_tokens, temperature=0.0)
        samples.append({"prompt": user, "reference": rec["chosen"], "rejected": rec["rejected"], "generated": generated})
    return samples
