"""Embedding index over a document set, and retrieval from it.

    python -m dragonfarm.retrieval index --dir SET [--model ID] [--force]
    python -m dragonfarm.retrieval retrieve --dir SET --query TEXT [-k 4]

The index is plain files next to the chunks:

    index/embeddings.npy   float16, one row per chunk, L2-normalised
    index/ids.json         chunk ids in row order
    manifest.json          gains an "index" block: model, pooling, dim, built_at,
                           and a signature of the chunk ids it was built from

Embeddings come from a small encoder through plain transformers (mean pooling
over the last hidden state), so nothing beyond what dragonfarm already
installs is needed. Scores are cosine similarity times the chunk's weight
(0.7 for changelog-like sources), so a changelog line has to be clearly
better to outrank the page that answers.

The worker keeps the encoder and the loaded indexes in memory between calls;
the command line builds or queries once and exits.
"""

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

DEFAULT_MODEL = "BAAI/bge-small-en-v1.5"
# bge models were trained with this instruction on the query side only; e5
# models (multilingual-e5) with a prefix on both sides.
QUERY_PREFIX = {"bge": "Represent this sentence for searching relevant passages: ", "e5": "query: "}
PASSAGE_PREFIX = {"e5": "passage: "}


def prefixes(model_id):
    """(query prefix, passage prefix) the model was trained with."""
    m = model_id.lower()
    q = next((p for key, p in QUERY_PREFIX.items() if key in m), "")
    d = next((p for key, p in PASSAGE_PREFIX.items() if key in m), "")
    return q, d


def chunk_signature(ids):
    return hashlib.sha256("\n".join(ids).encode("utf-8")).hexdigest()[:16]


class Encoder:
    """A sentence encoder: tokenizer + model, mean pooled, normalised."""

    def __init__(self, model_id=DEFAULT_MODEL, device=None, max_length=256):
        import torch
        from transformers import AutoModel, AutoTokenizer

        self.model_id = model_id
        self.max_length = max_length
        self.device = device or ("cuda" if torch.cuda.is_available() else "cpu")
        self.tok = AutoTokenizer.from_pretrained(model_id)
        self.model = AutoModel.from_pretrained(model_id).to(self.device).eval()
        self.query_prefix, self.passage_prefix = prefixes(model_id)

    def encode(self, texts, batch_size=32, prefix=""):
        import torch

        out = []
        for i in range(0, len(texts), batch_size):
            batch = [prefix + t for t in texts[i:i + batch_size]]
            enc = self.tok(batch, padding=True, truncation=True, max_length=self.max_length,
                           return_tensors="pt").to(self.device)
            with torch.no_grad():
                hidden = self.model(**enc).last_hidden_state
            mask = enc["attention_mask"].unsqueeze(-1).to(hidden.dtype)
            pooled = (hidden * mask).sum(1) / mask.sum(1).clamp(min=1)
            out.append(torch.nn.functional.normalize(pooled, dim=-1).float().cpu())
        return torch.cat(out) if out else torch.zeros((0, self.model.config.hidden_size))

    def encode_queries(self, texts):
        return self.encode(texts, prefix=self.query_prefix)

    def encode_passages(self, texts):
        return self.encode(texts, prefix=self.passage_prefix)


def _read_manifest(set_dir):
    with open(Path(set_dir) / "manifest.json", encoding="utf-8") as f:
        return json.load(f)


def _write_manifest(set_dir, manifest):
    with open(Path(set_dir) / "manifest.json", "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)


def _read_chunks(set_dir):
    with open(Path(set_dir) / "chunks.jsonl", encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def chunk_text_for_index(c):
    """What gets embedded: the section heading gives short chunks their topic."""
    section = (c.get("section") or "").strip()
    return (section + ". " + c["text"]) if section else c["text"]


def build_index(set_dir, encoder=None, model_id=DEFAULT_MODEL, force=False, log=None):
    """Embed every chunk of a set. Skips the work when the index already matches the chunks."""
    import numpy as np

    log = log or (lambda *_: None)
    set_dir = Path(set_dir)
    manifest = _read_manifest(set_dir)
    chunks = _read_chunks(set_dir)
    ids = [c["id"] for c in chunks]
    signature = chunk_signature(ids)
    existing = manifest.get("index") or {}
    if (not force and existing.get("signature") == signature and existing.get("model") == model_id
            and (set_dir / "index" / "embeddings.npy").exists()):
        log(f"index up to date ({len(ids)} chunks, {model_id})")
        return existing
    enc = encoder or Encoder(model_id)
    t0 = time.time()
    encode = getattr(enc, "encode_passages", enc.encode)   # stand-in encoders in tests have encode() only
    vectors = encode([chunk_text_for_index(c) for c in chunks]).numpy().astype("float16")
    (set_dir / "index").mkdir(exist_ok=True)
    np.save(set_dir / "index" / "embeddings.npy", vectors)
    with open(set_dir / "index" / "ids.json", "w", encoding="utf-8") as f:
        json.dump(ids, f)
    info = {"model": model_id, "pooling": "mean", "dim": int(vectors.shape[1]) if len(ids) else 0,
            "n_chunks": len(ids), "signature": signature,
            "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "seconds": round(time.time() - t0, 1)}
    manifest["index"] = info
    _write_manifest(set_dir, manifest)
    log(f"indexed {len(ids)} chunks with {model_id} in {info['seconds']}s")
    return info


_STOP = frozenset("a an the of to in for on and or is are was were be by with as at from that this it its "
                  "what how does do did which who when where why can i my our we you your".split())
RRF_K = 60   # reciprocal-rank-fusion constant; 60 is the usual choice and was not tuned


def keyword_tokens(text, query=False):
    """Lower-cased words and numbers ("$4,409", "10-k", "2.4") minus a few stop words.

    Tables read with their years ("Net sales (2024: $249,625; 2023: $237,710)")
    also give a "y2023" token per year-labelled value, and a question that names
    a year asks for it; a plain "2023" is everywhere in a report, so on its own
    it did little to pull up the row for that year."""
    import re

    toks = [t for t in re.findall(r"[a-z0-9][a-z0-9.,$%-]*[a-z0-9%]|[a-z0-9]", text.lower()) if t not in _STOP]
    if query:
        years = re.findall(r"\b((?:19|20)\d{2})\b", text)
    else:
        years = re.findall(r"\b((?:19|20)\d{2}): ", text)
    return toks + ["y" + y for y in years]


class BM25:
    """Okapi BM25 over the chunk texts. Built when an index is loaded: a few
    milliseconds per thousand chunks, nothing stored on disk."""

    def __init__(self, texts, k1=1.2, b=0.75):
        import math
        from collections import Counter

        toks = [keyword_tokens(t) for t in texts]
        self.lengths = [len(t) for t in toks]
        self.avg = (sum(self.lengths) / len(toks)) if toks else 0.0
        self.tf = [Counter(t) for t in toks]
        df = Counter()
        for t in toks:
            df.update(set(t))
        n = len(toks)
        self.idf = {w: math.log(1 + (n - c + 0.5) / (c + 0.5)) for w, c in df.items()}
        self.k1, self.b = k1, b

    def scores(self, query):
        import numpy as np

        out = np.zeros(len(self.tf), dtype="float32")
        q = keyword_tokens(query, query=True)
        if not q or not self.avg:
            return out
        for i, tf in enumerate(self.tf):
            norm = self.k1 * (1 - self.b + self.b * self.lengths[i] / self.avg)
            s = 0.0
            for w in q:
                f = tf.get(w)
                if f:
                    s += self.idf[w] * f * (self.k1 + 1) / (f + norm)
            out[i] = s
        return out


def _ranks(scores):
    import numpy as np

    order = np.argsort(-scores, kind="stable")
    r = np.empty(len(scores), dtype="float32")
    r[order] = np.arange(1, len(scores) + 1)
    return r


class LoadedIndex:
    def __init__(self, set_dir):
        import numpy as np

        set_dir = Path(set_dir)
        self.dir = set_dir
        self.manifest = _read_manifest(set_dir)
        self.info = self.manifest.get("index")
        if not self.info or not (set_dir / "index" / "embeddings.npy").exists():
            raise RuntimeError(f"{set_dir} has no index yet; run dragon_index() first")
        self.vectors = np.load(set_dir / "index" / "embeddings.npy").astype("float32")
        with open(set_dir / "index" / "ids.json", encoding="utf-8") as f:
            self.ids = json.load(f)
        chunks = {c["id"]: c for c in _read_chunks(set_dir)}
        if [i for i in self.ids if i not in chunks]:
            raise RuntimeError(f"the index in {set_dir} no longer matches its chunks; run dragon_index() again")
        self.chunks = [chunks[i] for i in self.ids]
        self.weights = np.array([float(c.get("weight", 1.0)) for c in self.chunks], dtype="float32")
        self.bm25 = BM25([chunk_text_for_index(c) for c in self.chunks])
        self.stamp = os.path.getmtime(set_dir / "index" / "embeddings.npy")

    def stale(self):
        try:
            return os.path.getmtime(self.dir / "index" / "embeddings.npy") != self.stamp
        except OSError:
            return True

    def search(self, query_vectors, k=4, queries=None, mode="hybrid", extra=0):
        """Top-k chunks per query: list of lists of {id, score, similarity}.

        mode "hybrid" (the default when query texts are given) ranks by
        reciprocal-rank fusion of the embedding ranking and a BM25 keyword
        ranking, each weighted by the chunk weight. Measured on three document
        sets, hit@4 for the chunk a question came from rose from 90.6 to 93.0
        percent (R manuals), 88 to 100 (package docs), and 91 to 100 (an annual
        report): keywords catch exact terms and numbers ("employees",
        "333,000") that the small embedding model ranks a few places too low.
        "dense" is the embedding ranking alone. score stays cosine x weight
        either way, so callers that show it see the same scale. extra adds that
        many chunks after the top k that say something different (see
        _different); the top k itself is unchanged."""
        import numpy as np

        if not len(self.ids):
            return [[] for _ in range(len(query_vectors))]
        sims = query_vectors.numpy() @ self.vectors.T           # cosine, since both sides are normalised
        scores = sims * self.weights[None, :]
        hybrid = mode == "hybrid" and queries is not None
        out = []
        k = max(1, min(int(k), len(self.ids)))
        for qi, (row, sim_row) in enumerate(zip(scores, sims)):
            if hybrid:
                kw = self.bm25.scores(queries[qi]) * self.weights
                # Only chunks that share a word with the question get a keyword
                # rank; ranking the zero scores too would hand the first chunks
                # in file order a boost they did nothing to earn.
                order_by = 1.0 / (RRF_K + _ranks(row)) + np.where(kw > 0, 1.0 / (RRF_K + _ranks(kw)), 0.0)
            else:
                order_by = row
            top = list(np.argsort(-order_by, kind="stable")[:k])
            if hybrid and k >= 3:
                # Keep the embedding's own best match among the excerpts. The
                # combined ranking can push it out when other chunks repeat the
                # question's words ("Costco", "locations"); in its last slot it
                # raised hit@4 on R's manuals from 92.9 to 94.3% and changed no
                # other set.
                best = int(np.argmax(row))
                if best not in top:
                    top[-1] = best
                # And the keyword ranking's best, when a word matched: a rare
                # exact term ("boxplot") puts its chunk first by keywords but
                # far down by embedding, and the fusion lost it.
                if k >= 4 and float(kw.max()) > 0:
                    kbest = int(np.argmax(kw))
                    if kbest not in top:
                        top[-2] = kbest
            if extra > 0:
                top += self._different(order_by, sim_row, top, int(extra))
            out.append([{"id": self.ids[i], "score": float(row[i]), "similarity": float(sim_row[i])} for i in top])
        return out

    def _different(self, order_by, sim_row, chosen, extra, window=30, lam=0.6):
        """Up to `extra` more chunks from the best `window`, each the most
        relevant (by embedding) and least like the chunks already chosen
        (maximal marginal relevance). A rule that several documents repeat and
        one later document words differently is otherwise crowded out of the
        top k by the repeats; with 2 extra chunks both versions reached the
        excerpts for 6 of 6 such rules, against 3 of 6 for the top 4 and 4 of 6
        for the top 8. Lambda 0.6 sits in the middle of the range that did."""
        import numpy as np

        pool = [int(i) for i in np.argsort(-order_by, kind="stable")[:window] if int(i) not in chosen]
        chosen = list(chosen)
        added = []
        while pool and len(added) < extra:
            red = np.max(self.vectors[pool] @ self.vectors[chosen].T, axis=1)
            score = lam * sim_row[pool] - (1 - lam) * red
            pick = pool.pop(int(np.argmax(score)))
            chosen.append(pick)
            added.append(pick)
        return added


class Retriever:
    """Encoder plus loaded indexes, kept warm by the worker."""

    def __init__(self):
        self.encoders = {}
        self.indexes = {}

    def encoder(self, model_id):
        if model_id not in self.encoders:
            self.encoders[model_id] = Encoder(model_id)
        return self.encoders[model_id]

    def index(self, set_dir, model_id=DEFAULT_MODEL, force=False):
        info = build_index(set_dir, encoder=self.encoder(model_id), model_id=model_id, force=force)
        self.indexes.pop(str(Path(set_dir)), None)
        return info

    def loaded(self, set_dir):
        key = str(Path(set_dir))
        idx = self.indexes.get(key)
        if idx is None or idx.stale():
            idx = self.indexes[key] = LoadedIndex(set_dir)
        return idx

    def retrieve(self, set_dir, queries, k=4, mode="hybrid", extra=0):
        idx = self.loaded(set_dir)
        enc = self.encoder(idx.info["model"])
        queries = list(queries)
        return idx.search(enc.encode_queries(queries), k=k, queries=queries, mode=mode, extra=extra)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m dragonfarm.retrieval")
    sub = ap.add_subparsers(dest="command", required=True)
    b = sub.add_parser("index")
    b.add_argument("--dir", required=True)
    b.add_argument("--model", default=DEFAULT_MODEL)
    b.add_argument("--force", action="store_true")
    r = sub.add_parser("retrieve")
    r.add_argument("--dir", required=True)
    r.add_argument("--query", required=True, action="append")
    r.add_argument("-k", type=int, default=4)
    a = ap.parse_args(argv)
    if a.command == "index":
        info = build_index(a.dir, model_id=a.model, force=a.force,
                           log=lambda m: print(f"[dragonfarm] {m}", file=sys.stderr, flush=True))
        print(json.dumps(info))
    else:
        print(json.dumps(Retriever().retrieve(a.dir, a.query, k=a.k)))


if __name__ == "__main__":
    main()
