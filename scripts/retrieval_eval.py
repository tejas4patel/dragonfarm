"""Measure document retrieval: does the chunk that answers a question reach
the top k excerpts? Compares the package's own search modes ("dense" and
"hybrid") on every indexed document set under a runs directory.

Two kinds of questions are used, both optional:

* Generated questions. For each set, the newest question file under
  <set>/questions/ supplies the kept questions, each with the chunk it was
  written from. Skipped for a set that was re-read after the questions were
  written (the chunk ids no longer line up), which the script detects from
  the chunks_md5 the question file's metadata records.
* Paraphrased questions (retrieval_eval_paraphrased.json, made by
  retrieval_paraphrased_make.R): 127 questions a 7B wrote in its own words
  from sampled passages, kept only when checked against them. Harder than
  the hand set (hybrid hit@4 87% against 98%); pass it with --hand.
* Hand-written questions from a JSON file (see retrieval_eval_questions.json):
  a list of {"set": name, "question": text, "answer_contains": text}; the
  target is any chunk whose text contains answer_contains.

Run from the repository root with the package's Python environment:

    python scripts/retrieval_eval.py                      # all sets in ~/dragonfarm_runs/documents
    python scripts/retrieval_eval.py --runs D:/runs --hand scripts/retrieval_eval_questions.json

Prints hit@1, hit@4, hit@8 and MRR (mean reciprocal rank of the first
right chunk in the top 20; 0 when it is not there) per set and mode, then a
total over all sets weighted by questions. No data is written.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "inst" / "python"))

from dragonfarm.retrieval import Encoder, LoadedIndex  # noqa: E402

KS = (1, 4, 8)
MRR_DEPTH = 20


def generated_questions(set_dir):
    qdir = set_dir / "questions"
    files = sorted(qdir.glob("*.jsonl")) if qdir.exists() else []
    if not files:
        return [], "no question set"
    f = files[-1]
    meta_path = Path(str(f) + ".meta.json")
    meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
    recorded = meta.get("chunks_md5")
    current = hashlib.md5((set_dir / "chunks.jsonl").read_bytes()).hexdigest()
    if recorded and recorded != current:
        return [], "set re-read after the questions were written"
    if not recorded and (set_dir / "chunks.jsonl").stat().st_mtime > f.stat().st_mtime:
        # Older question sets have no checksum; a chunks file newer than the
        # questions means the set was re-read and the ids may point elsewhere.
        return [], "set re-read after the questions were written (by date)"
    ids = {json.loads(line)["id"] for line in open(set_dir / "chunks.jsonl", encoding="utf-8")}
    rows = [json.loads(line) for line in open(f, encoding="utf-8")]
    items = [(r["question"], {r["chunk_id"]}) for r in rows if r.get("keep") and r.get("chunk_id") in ids]
    return items, f.name


def hand_questions(path, set_name, set_dir):
    if not path:
        return []
    chunks = [json.loads(line) for line in open(set_dir / "chunks.jsonl", encoding="utf-8")]
    out = []
    for q in json.loads(Path(path).read_text(encoding="utf-8")):
        if q.get("set") != set_name:
            continue
        targets = {c["id"] for c in chunks if q["answer_contains"] in c["text"]}
        if targets:
            out.append((q["question"], targets))
    return out


def score(idx, enc, items, mode):
    qs = [q for q, _ in items]
    vecs = enc.encode_queries(qs)
    res = {k: 0 for k in KS}
    for k in KS:
        # One search per k, as dragon_ask() does: the top k is not always the
        # first k of a longer list (hybrid search keeps the embedding's best
        # match in the last slot).
        hits = idx.search(vecs, k=k, queries=qs, mode=mode)
        for (_, targets), found in zip(items, hits):
            res[k] += any(h["id"] in targets for h in found)
    out = {k: res[k] / len(items) for k in KS}
    rr = 0.0
    for (_, targets), found in zip(items, idx.search(vecs, k=MRR_DEPTH, queries=qs, mode=mode)):
        rank = next((i + 1 for i, h in enumerate(found) if h["id"] in targets), None)
        rr += 1.0 / rank if rank else 0.0
    out["mrr"] = rr / len(items)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--runs", default=str(Path.home() / "dragonfarm_runs"), help="runs directory (default ~/dragonfarm_runs)")
    ap.add_argument("--hand", default=str(HERE / "retrieval_eval_questions.json"), help="hand-written questions (JSON)")
    ap.add_argument("--sets", nargs="*", help="only these set names")
    a = ap.parse_args(argv)

    docs = Path(a.runs) / "documents"
    sets = sorted(p for p in docs.iterdir() if (p / "index" / "embeddings.npy").exists()) if docs.exists() else []
    if a.sets:
        sets = [p for p in sets if p.name in a.sets]
    if not sets:
        print("no indexed document sets under", docs)
        return 1
    hand = a.hand if a.hand and Path(a.hand).exists() else None
    encoders = {}
    print(f"{'set':<22} {'questions':<34} {'mode':<7} " + " ".join(f"hit@{k:<3}" for k in KS) + "  MRR")
    totals = {}
    for set_dir in sets:
        idx = LoadedIndex(set_dir)
        model = idx.info["model"]
        enc = encoders.setdefault(model, Encoder(model))
        generated, note = generated_questions(set_dir)
        for label, items in (("generated", generated), ("hand", hand_questions(hand, set_dir.name, set_dir))):
            if not items:
                if label == "generated":
                    print(f"{set_dir.name:<22} {'generated: ' + note:<34}")
                continue
            desc = f"{label} ({len(items)})"
            for mode in ("dense", "hybrid"):
                r = score(idx, enc, items, mode)
                print(f"{set_dir.name:<22} {desc:<34} {mode:<7} " + " ".join(f"{r[k]:6.1%}" for k in KS) + f"  {r['mrr']:.3f}")
                t = totals.setdefault((label, mode), {"n": 0, **{k: 0.0 for k in (*KS, "mrr")}})
                t["n"] += len(items)
                for k in (*KS, "mrr"):
                    t[k] += r[k] * len(items)
    for (label, mode), t in totals.items():
        desc = f"{label} ({t['n']})"
        print(f"{'TOTAL':<22} {desc:<34} {mode:<7} " + " ".join(f"{t[k] / t['n']:6.1%}" for k in KS) + f"  {t['mrr'] / t['n']:.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
