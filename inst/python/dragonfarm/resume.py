"""Finding, trimming and restoring checkpoints when a run is resumed."""

import json
import os
from pathlib import Path


def checkpoint_complete(path: Path) -> bool:
    """transformers writes trainer_state.json last (after the weights, the
    optimizer and the random state), and save_reinforce_checkpoint() does the
    same, so a checkpoint whose state file is missing or cut short was
    interrupted while saving."""
    try:
        json.loads((Path(path) / "trainer_state.json").read_text(encoding="utf-8"))
        return True
    except (OSError, ValueError):
        return False


def checkpoint_step(path: Path) -> int:
    return int(Path(path).name.split("-")[-1])


def latest_checkpoint(run_dir: Path):
    """The newest complete checkpoint. A crash while saving leaves a partial
    folder; resuming from it would fail, so fall back to the one before."""
    ck = Path(run_dir) / "checkpoints"
    if not ck.exists():
        return None
    cands = [p for p in ck.iterdir() if p.is_dir() and p.name.startswith("checkpoint-")
             and p.name.split("-")[-1].isdigit()]
    for p in sorted(cands, key=checkpoint_step, reverse=True):
        if checkpoint_complete(p):
            return p
        print(f"[dragonfarm] skipping {p.name}: it was not saved completely", flush=True)
    return None


def write_json_atomic(path: Path, obj):
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(obj), encoding="utf-8")
    os.replace(tmp, path)


def trim_progress(run_dir: Path, step: int):
    """Drop progress rows logged after the checkpoint a run resumes from:
    those steps are trained again, and keeping both copies would draw them
    twice in the loss chart. Rows without a step are kept."""
    path = Path(run_dir) / "progress.jsonl"
    if not path.exists():
        return 0
    keep, dropped = [], 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            row_step = json.loads(line).get("step")
        except ValueError:
            dropped += 1          # a line cut short by the crash
            continue
        if row_step is not None and row_step > step:
            dropped += 1
        else:
            keep.append(line)
    tmp = Path(str(path) + ".tmp")
    tmp.write_text("".join(l + "\n" for l in keep), encoding="utf-8")
    os.replace(tmp, path)
    return dropped


def save_reinforce_checkpoint(model, optimizer, run_dir: Path, step: int):
    """Weights, then optimizer, then the state file last, as transformers does."""
    import torch
    ckpt = Path(run_dir) / "checkpoints" / f"checkpoint-{step}"
    model.save_pretrained(str(ckpt))
    torch.save(optimizer.state_dict(), ckpt / "optimizer.pt")
    write_json_atomic(ckpt / "trainer_state.json", {"global_step": int(step)})
    write_json_atomic(Path(run_dir) / "checkpoints" / "reinforce_state.json", {"step": int(step)})
    return ckpt


def restore_reinforce_checkpoint(model, optimizer, ckpt: Path):
    """Load the adapter weights and, when saved, the optimizer state."""
    import torch
    from peft import set_peft_model_state_dict
    from safetensors.torch import load_file
    ckpt = Path(ckpt)
    weights = ckpt / "adapter_model.safetensors"
    if not weights.exists():
        raise FileNotFoundError(f"{weights} is missing")
    set_peft_model_state_dict(model, load_file(str(weights)))
    opt = ckpt / "optimizer.pt"
    if opt.exists():
        optimizer.load_state_dict(torch.load(str(opt), map_location="cpu", weights_only=True))
    return opt.exists()
