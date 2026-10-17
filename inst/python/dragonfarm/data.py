"""Turn chat-format JSONL into token ids with the assistant turn as labels."""

import json
from pathlib import Path

import torch

IGNORE_INDEX = -100


def read_jsonl(path):
    records = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def has_chat_template(tok) -> bool:
    return bool(getattr(tok, "chat_template", None))


def fallback_prompt(messages) -> str:
    """Plain-text format for tokenizers that ship without a chat template."""
    parts = []
    for m in messages:
        role = m["role"]
        if role == "system":
            parts.append(f"### System:\n{m['content']}\n")
        elif role == "user":
            parts.append(f"### User:\n{m['content']}\n")
        elif role == "assistant":
            parts.append(f"### Assistant:\n{m['content']}\n")
    return "\n".join(parts)


def render_prompt(tok, messages, tools=None) -> str:
    """Text of the conversation up to and including the assistant cue. With
    `tools` (JSON Schema function specs), templates that support tool calling
    describe them to the model."""
    if has_chat_template(tok):
        if tools:
            return tok.apply_chat_template(messages, tools=tools, tokenize=False, add_generation_prompt=True)
        return tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    return fallback_prompt(messages) + "\n### Assistant:\n"


def render_full(tok, messages) -> str:
    """Text of the full conversation including the assistant reply."""
    if has_chat_template(tok):
        return tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=False)
    eos = tok.eos_token or ""
    return fallback_prompt(messages) + eos


def encode_example(tok, messages, max_len):
    """Return input_ids and labels, or None if nothing trainable survives."""
    if not messages or messages[-1]["role"] != "assistant":
        raise ValueError("each example must end with an assistant message")
    prompt_text = render_prompt(tok, messages[:-1])
    full_text = render_full(tok, messages)

    prompt_ids = tok(prompt_text, add_special_tokens=False)["input_ids"]
    full_ids = tok(full_text, add_special_tokens=False)["input_ids"]

    n_prompt = len(prompt_ids)
    if full_ids[:n_prompt] != prompt_ids:
        # Tokenization boundary differs; fall back to the longest common prefix.
        n_prompt = 0
        for a, b in zip(full_ids, prompt_ids):
            if a != b:
                break
            n_prompt += 1

    labels = [IGNORE_INDEX] * n_prompt + full_ids[n_prompt:]
    input_ids = full_ids[:max_len]
    labels = labels[:max_len]
    if all(l == IGNORE_INDEX for l in labels):
        return None
    return {"input_ids": input_ids, "labels": labels}


class ChatDataset(torch.utils.data.Dataset):
    def __init__(self, records, tok, max_len):
        self.items = []
        self.skipped = 0
        for rec in records:
            enc = encode_example(tok, rec["messages"], max_len)
            if enc is None:
                self.skipped += 1
            else:
                self.items.append(enc)

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        return self.items[i]


def load_split(path, tok, max_len):
    records = read_jsonl(Path(path))
    ds = ChatDataset(records, tok, max_len)
    return ds, records


class PadCollator:
    """Right-pad input_ids with pad_token_id and labels with IGNORE_INDEX."""

    def __init__(self, pad_token_id):
        self.pad = pad_token_id

    def __call__(self, batch):
        width = max(len(b["input_ids"]) for b in batch)
        ids, labels, mask = [], [], []
        for b in batch:
            n = len(b["input_ids"])
            ids.append(b["input_ids"] + [self.pad] * (width - n))
            labels.append(b["labels"] + [IGNORE_INDEX] * (width - n))
            mask.append([1] * n + [0] * (width - n))
        return {
            "input_ids": torch.tensor(ids, dtype=torch.long),
            "labels": torch.tensor(labels, dtype=torch.long),
            "attention_mask": torch.tensor(mask, dtype=torch.long),
        }


# Preference pairs -----------------------------------------------------------


def encode_pair(tok, prompt_msgs, chosen, rejected, max_len):
    """Tokenize prompt+chosen and prompt+rejected with the prompt masked out.

    Returns None when either side has no trainable tokens left after
    truncation, which happens when the prompt alone fills ``max_len``.
    """
    def enc(response):
        return encode_example(tok, list(prompt_msgs) + [{"role": "assistant", "content": response}], max_len)

    c, r = enc(chosen), enc(rejected)
    if c is None or r is None:
        return None
    return {
        "chosen_input_ids": c["input_ids"], "chosen_labels": c["labels"],
        "rejected_input_ids": r["input_ids"], "rejected_labels": r["labels"],
    }


class PairDataset(torch.utils.data.Dataset):
    def __init__(self, records, tok, max_len):
        self.items = []
        self.skipped = 0
        for rec in records:
            enc = encode_pair(tok, rec["prompt"], rec["chosen"], rec["rejected"], max_len)
            if enc is None:
                self.skipped += 1
            else:
                self.items.append(enc)

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        return self.items[i]


def load_pairs_split(path, tok, max_len):
    records = read_jsonl(Path(path))
    return PairDataset(records, tok, max_len), records


class PairCollator:
    """Pad chosen and rejected sides separately; the trainer aligns them."""

    def __init__(self, pad_token_id):
        self.pad = pad_token_id

    def _side(self, batch, side):
        width = max(len(b[f"{side}_input_ids"]) for b in batch)
        ids, labels, mask = [], [], []
        for b in batch:
            seq, lab = b[f"{side}_input_ids"], b[f"{side}_labels"]
            n = len(seq)
            ids.append(seq + [self.pad] * (width - n))
            labels.append(lab + [IGNORE_INDEX] * (width - n))
            mask.append([1] * n + [0] * (width - n))
        return {
            f"{side}_input_ids": torch.tensor(ids, dtype=torch.long),
            f"{side}_labels": torch.tensor(labels, dtype=torch.long),
            f"{side}_attention_mask": torch.tensor(mask, dtype=torch.long),
        }

    def __call__(self, batch):
        out = self._side(batch, "chosen")
        out.update(self._side(batch, "rejected"))
        return out
