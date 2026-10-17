"""Questions and answers written from a document set's chunks, then filtered.

    python -m dragonfarm.questions prompts  --dir SET [selection flags]           -> JSON [{chunk_id, prompt}]
    python -m dragonfarm.questions generate --dir SET --out FILE --model ID [...]  -> writes FILE (+ .progress.json, .meta.json)
    python -m dragonfarm.questions filter   --dir SET --raw RAW.json --out FILE    -> parses and filters a teacher's raw outputs

One prompt per chunk asks for N self-contained questions each answered from
that chunk alone. Every parsed pair is kept in the output with a `keep` flag
and, when rejected, a `reason`, so a person can see what the filters did and
rescue a pair. The filters are deliberately simple and deterministic:
grounding (how much of the answer's vocabulary is in the chunk), names not in
the source, "the passage"-style references, lengths, duplicates.

Measured on the package's own documentation (scripts/doc_prototype): about
20% of a 1.5B's pairs were usable, 33% of a 3B's, 60% of a 7B's. The review
step is not optional at any size.
"""

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

PROMPT = ('Passage from a document (file: {source}, section: "{section}"):\n'
          '"""\n{text}\n"""\n\n'
          'Write {n} different questions that a reader of this document might ask, each fully answered by this passage alone. '
          'Make every question self-contained: name the thing it is about, and never mention "the passage", "the text" '
          'or "the document". Then answer each question in one or two sentences, using only facts stated in the passage.\n'
          'Use exactly this format:\n')

STOP = set("a an the and or of to in on is it for with as at by be this that are was can you your i my not if from "
           "then so do does will which what how when into than also its their they them these those has have use used "
           "using allows allow user users function feature software provides provide".split())
META = re.compile(r"\b(the passage|this passage|the text|this text|the document|this document|the section|the article|"
                  r"the excerpt|according to the)\b", re.I)
GROUNDING_THRESHOLD = 0.55


MAX_PASSAGE_WORDS = 450


def passage(chunk, max_words=MAX_PASSAGE_WORDS):
    """The chunk text as shown to the generator: whole for prose, cut for a long code block."""
    words = chunk["text"].split()
    if len(words) <= max_words:
        return chunk["text"]
    return " ".join(words[:max_words]) + " ..."


# Asked of the generator when a mix of question types is wanted: without it a
# 7B writes almost only "What is X?" questions whose answers restate a line.
MIX = ("Vary the kinds of question: one asks what or which, one asks why or how (a reason, a purpose, or the steps "
       "to do something), and, if the passage compares or contrasts two things, one asks how they differ. ")


def prompt_for(chunk, n, mix=False):
    fmt = "\n".join(f"Q{i}: ...\nA{i}: ..." for i in range(1, n + 1))
    p = PROMPT.format(n=n, source=chunk["source"], section=chunk.get("section") or "", text=passage(chunk))
    if mix:
        p = p.replace("Use exactly this format:", MIX + "Use exactly this format:")
    return p + fmt


def generate_batch(batch, gen_fn, log=None):
    """Outputs for a batch of chunks as (chunk id, text), surviving GPU memory errors:
    a batch that does not fit is retried one chunk at a time, and a single chunk that
    still does not fit is skipped and reported. gen_fn(list of chunks) -> list of texts."""
    from .evaluate_utils import free_gpu_memory, is_oom

    try:
        return [(c["id"], t) for c, t in zip(batch, gen_fn(batch))], []
    except Exception as e:
        if not is_oom(e) or len(batch) == 0:
            raise
        free_gpu_memory()
    if len(batch) == 1:
        if log:
            log(f"[dragonfarm] chunk {batch[0]['id']} ({batch[0].get('source')}) does not fit in GPU memory even alone; skipped")
        return [], [batch[0]["id"]]
    if log:
        log(f"[dragonfarm] batch of {len(batch)} ran out of GPU memory; retrying one chunk at a time")
    outputs, skipped = [], []
    for c in batch:
        o, sk = generate_batch([c], gen_fn, log)
        outputs += o
        skipped += sk
    return outputs, skipped


# A Q/A label at the start of a line, with the Markdown some models wrap it
# in: "**Q1:**", "**Q1**:", "### Q1:", "- Q1.". A 1.5B wrote every label in
# bold, and all of its replies were thrown away as unparsed.
LABEL = re.compile(r"^[ \t>#*_-]*(?:\*\*|__)?\s*([QA])(\d+)\s*(?:\*\*|__)?\s*[:.)]\s*(?:\*\*|__)?[ \t]*", re.M)


def parse(output):
    output = LABEL.sub(lambda m: f"{m.group(1)}{m.group(2)}: ", output)
    pairs = []
    for m in re.finditer(r"Q(\d+)\s*:\s*(.+?)\s*\n+\s*A\1\s*:\s*(.+?)(?=\n+\s*Q\d+\s*:|\Z)", output, re.S):
        q = re.sub(r"\s+", " ", m.group(2)).strip().strip("*_ ").strip()
        a = re.sub(r"\s+", " ", m.group(3)).strip().strip("*_ ").strip()
        pairs.append((q, a))
    return pairs


def stem(t):
    return re.sub(r"(ing|ed|es|s)$", "", t) if len(t) > 4 else t


def content(s):
    return [stem(t) for t in re.findall(r"[a-z0-9_.\-]+", s.lower()) if t not in STOP and len(t) > 1]


def identifiers(s):
    """Code-like tokens: snake_case names, calls with (), file names, versions."""
    ids = set(re.findall(r"[A-Za-z]+_[A-Za-z_]+|[A-Za-z_.]+\(\)|\w+\.(?:R|Rmd|json|jsonl|py|md|csv|pdf)\b|\b\d+\.\d+(?:\.\d+)?\b", s))
    return {i.rstrip("()").lower() for i in ids}


def grounding(answer, ctx):
    toks = content(answer)
    if not toks:
        return 0.0
    cset = set(content(ctx))
    return sum(t in cset for t in toks) / len(toks)


def unknown_ids(text, ctx):
    have = identifiers(ctx) | set(re.findall(r"[a-z0-9_.]+", ctx.lower()))
    return sorted(i for i in identifiers(text) if i not in have)


def judge(q, a, chunk, seen):
    """None when the pair passes, else a short reason."""
    ctx = f'{chunk["source"]} {chunk.get("section") or ""}\n{chunk["text"]}'
    if not (5 <= len(q.split()) <= 45):
        return "question length"
    if not q.rstrip().endswith("?"):
        return "not a question"
    if not (3 <= len(a.split()) <= 90):
        return "answer length"
    if META.search(q) or META.search(a):
        return "refers to the passage"
    bad = unknown_ids(a, ctx) + unknown_ids(q, ctx)
    if bad:
        return f"names not in the source ({bad[0]})"
    g = grounding(a, ctx)
    if g < GROUNDING_THRESHOLD:
        return f"answer not grounded ({g:.2f})"
    qs = set(content(q))
    for s in seen:
        if len(qs & s) / max(1, len(qs | s)) > 0.8:
            return "duplicate question"
    seen.append(qs)
    return None


def chunks_md5(set_dir):
    """MD5 of the set's chunks.jsonl as written: recorded with a question set so a
    later re-read of the documents (which renumbers chunk ids) can be noticed."""
    import hashlib

    with open(Path(set_dir) / "chunks.jsonl", "rb") as fh:
        return hashlib.md5(fh.read()).hexdigest()


def load_chunks(set_dir):
    with open(Path(set_dir) / "chunks.jsonl", encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def select_chunks(chunks, include_quotes=False, include_code=True, include_changelog=False, chunk_ids=None):
    out = []
    for c in chunks:
        if chunk_ids is not None and c["id"] not in chunk_ids:
            continue
        if c.get("quoted") and not include_quotes:
            continue
        if c.get("code") and not include_code:
            continue
        if float(c.get("weight", 1.0)) < 1.0 and not include_changelog:
            continue
        out.append(c)
    return out


def filter_outputs(chunks, outputs):
    """(chunk, raw output) pairs -> rows with keep/reason. Keeps order; ids are p0001, ..."""
    by_id = {c["id"]: c for c in chunks}
    rows, seen, unparsed = [], [], 0
    for chunk_id, output in outputs:
        c = by_id[chunk_id]
        ps = parse(output or "")
        if not ps:
            unparsed += 1
        for q, a in ps:
            why = judge(q, a, c, seen)
            rows.append({"id": f"p{len(rows) + 1:04d}", "chunk_id": c["id"], "source": c["source"],
                         "section": c.get("section") or "", "question": q, "answer": a,
                         "keep": why is None, "reason": why, "decided_by": "filter"})
    return rows, unparsed


def write_rows(path, rows):
    tmp = str(path) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def write_json(path, obj):
    tmp = str(path) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def generate(set_dir, out, model_id, n=3, load_in_4bit="auto", batch_size=4, max_new_tokens=420,
             include_quotes=False, include_code=True, include_changelog=False, chunk_ids=None, mix=False, revision=None):
    import torch
    from transformers import AutoTokenizer

    from .hardware import resolve, wants_4bit
    from .loading import load_for_inference

    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    progress_path = Path(str(out) + ".progress.json")
    chunks = select_chunks(load_chunks(set_dir), include_quotes, include_code, include_changelog, chunk_ids)
    meta = {"generator": model_id, "n_per_chunk": n, "n_chunks": len(chunks), "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "include_quotes": include_quotes, "include_code": include_code, "include_changelog": include_changelog,
            "chunks_md5": chunks_md5(set_dir), "mix": bool(mix)}
    write_json(progress_path, {"state": "loading", "done": 0, "total": len(chunks), "pairs": 0, "kept": 0})
    if not chunks:
        write_rows(out, [])
        write_json(Path(str(out) + ".meta.json"), {**meta, "n_pairs": 0, "n_kept": 0, "unparsed": 0,
                                                     "finished_at": meta["started_at"], "load_in_4bit": False})
        write_json(progress_path, {"state": "done", "done": 0, "total": 0, "pairs": 0, "kept": 0})
        return

    hw = resolve({"device": "auto", "dtype": "auto"})
    four_bit = wants_4bit(load_in_4bit, model_id, hw.kind, hw.vram_gb)
    tok = AutoTokenizer.from_pretrained(model_id, revision=revision, padding_side="left")
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    model = load_for_inference(model_id, hw, revision=revision, load_in_4bit=four_bit)
    meta["load_in_4bit"] = four_bit
    print(f"[dragonfarm] writing questions for {len(chunks)} chunks with {model_id}" + (" (4-bit)" if four_bit else ""),
          file=sys.stderr, flush=True)

    def gen_fn(batch):
        texts = [tok.apply_chat_template([{"role": "user", "content": prompt_for(c, n, mix)}], tokenize=False,
                                         add_generation_prompt=True) for c in batch]
        enc = tok(texts, return_tensors="pt", padding=True, truncation=True, max_length=2048).to(hw.device)
        with torch.no_grad():
            gen = model.generate(**enc, max_new_tokens=max_new_tokens, do_sample=False, pad_token_id=tok.pad_token_id)
        return [tok.decode(seq[enc["input_ids"].shape[1]:], skip_special_tokens=True) for seq in gen]

    def log(msg):
        print(msg, file=sys.stderr, flush=True)

    outputs, rows, skipped = [], [], []
    for i in range(0, len(chunks), batch_size):
        batch = chunks[i:i + batch_size]
        o, sk = generate_batch(batch, gen_fn, log)
        outputs += o
        skipped += sk
        # Filter what we have so far so the progress file can show the yield as it grows.
        rows, _ = filter_outputs(chunks, outputs)
        write_rows(out, rows)
        write_json(progress_path, {"state": "running", "done": len(outputs), "total": len(chunks),
                                   "pairs": len(rows), "kept": sum(r["keep"] for r in rows)})
    rows, unparsed = filter_outputs(chunks, outputs)
    write_rows(out, rows)
    with open(Path(str(out) + ".raw.json"), "w", encoding="utf-8") as f:
        json.dump([{"chunk_id": cid, "output": text} for cid, text in outputs], f, ensure_ascii=False)
    write_json(Path(str(out) + ".meta.json"), {**meta, "n_pairs": len(rows), "n_kept": sum(r["keep"] for r in rows),
                                                 "unparsed": unparsed, "skipped_oom": skipped,
                                                 "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    write_json(progress_path, {"state": "done", "done": len(chunks), "total": len(chunks), "pairs": len(rows),
                               "kept": sum(r["keep"] for r in rows)})


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m dragonfarm.questions")
    sub = ap.add_subparsers(dest="command", required=True)

    def selection(p):
        p.add_argument("--dir", required=True)
        p.add_argument("--per-chunk", type=int, default=3)
        p.add_argument("--include-quotes", action="store_true")
        p.add_argument("--skip-code", action="store_true")
        p.add_argument("--include-changelog", action="store_true")
        p.add_argument("--chunk-ids", default=None, help="comma-separated subset")
        p.add_argument("--mix", action="store_true", help="ask for a mix of question types")

    p = sub.add_parser("prompts"); selection(p)
    g = sub.add_parser("generate"); selection(g)
    g.add_argument("--out", required=True)
    g.add_argument("--model", required=True)
    g.add_argument("--revision", default=None)
    g.add_argument("--load-in-4bit", default="auto")
    g.add_argument("--batch-size", type=int, default=4)
    g.add_argument("--max-new-tokens", type=int, default=420)
    f = sub.add_parser("filter")
    f.add_argument("--dir", required=True)
    f.add_argument("--raw", required=True)
    f.add_argument("--out", required=True)
    f.add_argument("--generator", default="teacher")
    a = ap.parse_args(argv)

    if a.command == "filter":
        chunks = load_chunks(a.dir)
        with open(a.raw, encoding="utf-8") as fh:
            raw = json.load(fh)
        rows, unparsed = filter_outputs(chunks, [(r["chunk_id"], r["output"]) for r in raw])
        write_rows(a.out, rows)
        write_json(Path(a.out + ".meta.json"), {"generator": a.generator, "n_chunks": len(raw), "n_pairs": len(rows),
                                                "chunks_md5": chunks_md5(a.dir),
                                                "n_kept": sum(r["keep"] for r in rows), "unparsed": unparsed,
                                                "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
        print(json.dumps({"n_pairs": len(rows), "n_kept": sum(r["keep"] for r in rows), "unparsed": unparsed}))
        return

    ids = set(a.chunk_ids.split(",")) if a.chunk_ids else None
    kw = dict(include_quotes=a.include_quotes, include_code=not a.skip_code, include_changelog=a.include_changelog, chunk_ids=ids)
    if a.command == "prompts":
        chunks = select_chunks(load_chunks(a.dir), **kw)
        print(json.dumps([{"chunk_id": c["id"], "prompt": prompt_for(c, a.per_chunk, a.mix)} for c in chunks], ensure_ascii=False))
        return
    four = {"true": True, "false": False}.get(str(a.load_in_4bit).lower(), "auto")
    generate(a.dir, a.out, a.model, n=a.per_chunk, load_in_4bit=four, batch_size=a.batch_size,
             max_new_tokens=a.max_new_tokens, mix=a.mix, revision=a.revision, **kw)


if __name__ == "__main__":
    main()
