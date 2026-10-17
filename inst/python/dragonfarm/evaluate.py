"""Entry point: python -m dragonfarm.evaluate --run-dir <dir> [--n-samples N]

Recomputes the held-out evaluation and sample generations for a finished run
using the saved adapter, writing eval.json and samples.json. Stage-aware:
SFT runs report loss and perplexity, preference runs report preference
accuracy and reward margin.
"""

import argparse
import json
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--n-samples", type=int, default=10)
    a = ap.parse_args()
    run_dir = Path(a.run_dir).resolve()
    with open(run_dir / "config.json", encoding="utf-8") as f:
        cfg = json.load(f)

    from .evaluate_utils import write_eval_files
    from .hardware import resolve
    from .train import eval_batch_size
    from .loading import load_for_inference, load_tokenizer

    adapter = run_dir / "adapter"
    if not adapter.exists():
        raise SystemExit("no adapter directory in this run; training did not finish")
    hw = resolve(cfg.get("hardware"))
    m = cfg["model"]
    base_adapters = [run_dir / p for p in (m.get("base_adapters") or [])]
    tok = load_tokenizer(m["id"], m.get("revision"), m.get("trust_remote_code", False))
    model = load_for_inference(m["id"], hw, adapter=adapter, revision=m.get("revision"),
                               trust_remote_code=m.get("trust_remote_code", False),
                               base_adapters=base_adapters, allow_pickle=bool(m.get("allow_pickle", False)))
    max_len = int(cfg["train"]["max_seq_len"])
    stage = cfg.get("stage", "sft")

    metrics, samples = None, []
    if cfg["data"].get("eval"):
        if stage == "reinforce":
            from .reinforce import eval_reinforce, read_prompt_records
            from .rewards import RewardSet

            rl = cfg.get("reinforce") or {}
            records = read_prompt_records(run_dir / cfg["data"]["eval"])
            rewards = RewardSet(rl.get("rewards") or [], run_dir=run_dir)
            metrics, samples = eval_reinforce(model, tok, rewards, records, hw.device,
                                              int(rl.get("max_new_tokens", 128)), a.n_samples)
        elif stage == "prefer":
            from .data import load_pairs_split
            from .prefer import eval_pairs, sample_pair_generations

            pref = cfg.get("prefer") or {}
            eval_ds, records = load_pairs_split(run_dir / cfg["data"]["eval"], tok, max_len)
            if len(eval_ds):
                metrics = eval_pairs(model, eval_ds, tok.pad_token_id, hw.device,
                                     pref.get("method", "dpo"), float(pref.get("beta", 0.1)),
                                     batch_size=eval_batch_size(cfg))
                samples = sample_pair_generations(model, tok, records, hw.device, n=a.n_samples)
        else:
            from .data import load_split
            from .evaluate_utils import eval_loss, sample_generations

            eval_ds, records = load_split(run_dir / cfg["data"]["eval"], tok, max_len)
            if len(eval_ds):
                metrics = eval_loss(model, eval_ds, tok.pad_token_id, hw.device, batch_size=eval_batch_size(cfg))
                samples = sample_generations(model, tok, records, hw.device, n=a.n_samples)
    write_eval_files(run_dir, metrics, samples)
    print(json.dumps({"metrics": metrics, "n_samples": len(samples)}))


if __name__ == "__main__":
    main()
