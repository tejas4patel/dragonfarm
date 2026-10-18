"""Index building, reuse, weighting, and search, with a stub encoder (no model download)."""

import json
import tempfile
from pathlib import Path

import torch

from dragonfarm import documents as D
from dragonfarm import retrieval as R

VOCAB = ["return", "refund", "days", "warranty", "year", "wifi", "router", "band", "reset", "app", "version", "changelog"]


class StubEncoder:
    """Bag-of-words over a tiny vocabulary, normalised: deterministic and cheap."""

    model_id = "stub"
    query_prefix = ""

    def encode(self, texts, batch_size=32, prefix=""):
        rows = []
        for t in texts:
            words = t.lower().replace(".", " ").replace(",", " ").split()
            v = torch.tensor([float(sum(w.startswith(tok) for w in words)) for tok in VOCAB]) + 1e-3
            rows.append(v / v.norm())
        return torch.stack(rows)

    def encode_queries(self, texts):
        return self.encode(texts)


def _make_set(tmp):
    src = Path(tmp) / "src"
    src.mkdir()
    (src / "policy.md").write_text(
        "# Returns\n\n" + "Any device can be returned within 30 days of delivery for a full refund. " * 6 +
        "\n\n# Warranty\n\n" + "Every device carries a 2-year warranty from delivery; a warranty claim needs the serial number. " * 6 +
        "\n\n# Wi-Fi\n\n" + "Wi-Fi drops come from band steering on mesh routers; reset the device and use the 2.4 GHz band. " * 6,
        encoding="utf-8")
    (src / "NEWS.md").write_text("# 1.2.0\n\n" + "Changelog: the return flow and refund timing changed in this version. " * 8, encoding="utf-8")
    out = Path(tmp) / "set"
    D.build([str(src)], out, "t", max_words=120, min_words=20)
    return out


def test_index_is_built_reused_and_rebuilt_when_chunks_change():
    with tempfile.TemporaryDirectory() as tmp:
        out = _make_set(tmp)
        enc = StubEncoder()
        logs = []
        info = R.build_index(out, encoder=enc, model_id="stub", log=logs.append)
        assert info["n_chunks"] == 4 and info["dim"] == len(VOCAB) and info["model"] == "stub"
        assert (out / "index" / "embeddings.npy").exists()
        manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
        assert manifest["index"]["signature"] == info["signature"]

        again = R.build_index(out, encoder=enc, model_id="stub", log=logs.append)
        assert again == info and any("up to date" in m for m in logs)

        forced = R.build_index(out, encoder=enc, model_id="stub", force=True)
        assert forced["signature"] == info["signature"]

        # A changed chunk set invalidates the index: documents.build drops the stale block.
        (Path(tmp) / "src" / "policy.md").write_text("# Only\n\n" + "Something else entirely about the app version. " * 10, encoding="utf-8")
        D.build([str(Path(tmp) / "src")], out, "t", max_words=120, min_words=20)
        manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
        assert manifest["index"] is None
        rebuilt = R.build_index(out, encoder=enc, model_id="stub")
        assert rebuilt["signature"] != info["signature"]


def test_search_ranks_by_similarity_times_weight():
    with tempfile.TemporaryDirectory() as tmp:
        out = _make_set(tmp)
        enc = StubEncoder()
        R.build_index(out, encoder=enc, model_id="stub")
        idx = R.LoadedIndex(out)
        hits = idx.search(enc.encode_queries(["How long is the warranty?"]), k=2)[0]
        assert [h["id"] for h in hits][0].endswith("-001") or "warranty" in idx.chunks[idx.ids.index(hits[0]["id"])]["text"].lower()
        # the changelog chunk talks about returns and refunds too, but is down-weighted below the policy
        hits = idx.search(enc.encode_queries(["return refund days"]), k=2)[0]
        top = idx.chunks[idx.ids.index(hits[0]["id"])]
        assert top["source"] == "policy.md" and top["section"] == "Returns"
        news = [h for h in hits if idx.chunks[idx.ids.index(h["id"])]["source"] == "NEWS.md"]
        assert all(abs(h["score"] - 0.7 * h["similarity"]) < 1e-6 for h in news)
        assert len(idx.search(enc.encode_queries(["x"]), k=99)[0]) == 4   # k is capped at the chunk count


def test_loaded_index_detects_a_rebuild():
    with tempfile.TemporaryDirectory() as tmp:
        out = _make_set(tmp)
        enc = StubEncoder()
        R.build_index(out, encoder=enc, model_id="stub")
        idx = R.LoadedIndex(out)
        assert not idx.stale()
        import os, time
        time.sleep(0.05)
        R.build_index(out, encoder=enc, model_id="stub", force=True)
        os.utime(out / "index" / "embeddings.npy", None)
        assert idx.stale()


def test_missing_index_is_a_clear_error():
    with tempfile.TemporaryDirectory() as tmp:
        out = _make_set(tmp)
        try:
            R.LoadedIndex(out)
        except RuntimeError as e:
            assert "dragon_index" in str(e)
        else:
            raise AssertionError("expected RuntimeError")


def test_chunk_signature_depends_on_ids_only():
    assert R.chunk_signature(["a", "b"]) == R.chunk_signature(["a", "b"])
    assert R.chunk_signature(["a", "b"]) != R.chunk_signature(["b", "a"])


def test_keyword_tokens_keep_numbers_and_drop_stop_words():
    assert R.keyword_tokens("How many employees did Costco have? 333,000 and $4,409.") == \
        ["many", "employees", "costco", "have", "333,000", "4,409"]   # "$" dropped: tables write "$ 4,409" or "(4,409)"


def test_bm25_prefers_the_chunk_with_the_exact_terms():
    bm = R.BM25(["We employed 333,000 employees worldwide.", "Warehouses opened in Japan and Korea.",
                 "Employees receive wage increases."])
    s = bm.scores("how many employees at year end 333,000")
    assert s.argmax() == 0 and s[1] == 0


def test_hybrid_search_lifts_a_keyword_match_the_embedding_ranks_low():
    import numpy as np

    class Vec:
        def __init__(self, a):
            self.a = np.asarray(a, dtype="float32")

        def numpy(self):
            return self.a

    idx = R.LoadedIndex.__new__(R.LoadedIndex)
    idx.ids = ["a", "b", "c", "d"]
    idx.chunks = [{"text": t} for t in ["Warehouse openings by country.", "Membership fee revenue.",
                                         "Executive officers.", "We employed 333,000 employees at year end."]]
    idx.vectors = np.eye(4, dtype="float32")
    idx.weights = np.ones(4, dtype="float32")
    idx.bm25 = R.BM25([c["text"] for c in idx.chunks])
    q = Vec([[0.9, 0.8, 0.7, 0.1]])          # the embedding puts the employee chunk last
    dense = [h["id"] for h in idx.search(q, k=2)[0]]
    hybrid = [h["id"] for h in idx.search(q, k=2, queries=["How many employees at year end?"])[0]]
    assert dense == ["a", "b"]
    assert "d" in hybrid
    assert idx.search(q, k=2, queries=["employees"], mode="dense")[0][0]["id"] == "a"
    # scores keep the cosine x weight scale whatever the ordering
    by_id = {h["id"]: h["score"] for h in idx.search(q, k=4, queries=["employees"])[0]}
    assert abs(by_id["d"] - 0.1) < 1e-6 and abs(by_id["a"] - 0.9) < 1e-6


def test_chunks_without_any_keyword_match_get_no_keyword_boost():
    import numpy as np

    class Vec:
        def __init__(self, a):
            self.a = np.asarray(a, dtype="float32")

        def numpy(self):
            return self.a

    idx = R.LoadedIndex.__new__(R.LoadedIndex)
    idx.ids = ["row1", "row2", "row3", "notes"]
    idx.chunks = [{"text": t} for t in ["State: Alabama; Population: 3615", "State: Alaska; Population: 365",
                                         "State: Arizona; Population: 2212", "Source: Statistical Abstract, 1977"]]
    idx.vectors = np.eye(4, dtype="float32")
    idx.weights = np.ones(4, dtype="float32")
    idx.bm25 = R.BM25([c["text"] for c in idx.chunks])
    q = Vec([[0.3, 0.29, 0.28, 0.9]])                   # the embedding prefers the notes chunk
    top = idx.search(q, k=1, queries=["Where does this come from?"])[0][0]["id"]   # no word in common with any chunk
    assert top == "notes"


def test_hybrid_keeps_the_embeddings_best_match_among_the_excerpts():
    import numpy as np

    class Vec:
        def __init__(self, a):
            self.a = np.asarray(a, dtype="float32")

        def numpy(self):
            return self.a

    texts = ["Costco locations Costco locations in Japan", "Costco locations in Korea and Costco",
             "Costco locations Costco in Canada", "Costco locations Costco Spain",
             "Costco locations Costco Mexico", "CALIFORNIA 140 ALABAMA 5 ALASKA 5"]
    idx = R.LoadedIndex.__new__(R.LoadedIndex)
    idx.ids = [str(i) for i in range(len(texts))]
    idx.chunks = [{"text": t} for t in texts]
    idx.vectors = np.eye(len(texts), dtype="float32")
    idx.weights = np.ones(len(texts), dtype="float32")
    idx.bm25 = R.BM25(texts)
    q = Vec([[0.5, 0.5, 0.5, 0.5, 0.5, 0.9]])        # the embedding's best match is the state list
    hits = [h["id"] for h in idx.search(q, k=4, queries=["How many Costco locations are there"])[0]]
    assert "5" in hits and hits[-1] == "5"           # kept, in the last slot
    top1 = idx.search(q, k=1, queries=["How many Costco locations are there"])[0]
    assert len(top1) == 1                            # k below 3: the combined ranking alone


def test_keyword_index_includes_the_section_title():
    import numpy as np

    idx = R.LoadedIndex.__new__(R.LoadedIndex)
    idx.ids = ["a", "b"]
    idx.chunks = [{"text": "Figures for the year.", "section": "Consolidated statements of income"},
                  {"text": "Figures for the year.", "section": "Legal proceedings"}]
    idx.vectors = np.eye(2, dtype="float32")
    idx.weights = np.ones(2, dtype="float32")
    idx.bm25 = R.BM25([R.chunk_text_for_index(c) for c in idx.chunks])
    s = idx.bm25.scores("income statement")
    assert s[0] > s[1]


def test_a_question_naming_a_year_finds_that_years_labelled_row():
    from dragonfarm.retrieval import BM25, keyword_tokens

    assert "y2023" in keyword_tokens("Net sales (2024: $249,625; 2023: $237,710)")
    assert "y2023" not in keyword_tokens("In 2023 we opened new warehouses.")      # a plain year is not a label
    assert "y2023" in keyword_tokens("What were net sales in fiscal 2023?", query=True)
    texts = [
        "Net sales grew 5 percent in 2024 to $249.6 billion, up from 2023, a record year for net sales.",
        "Total company net sales increased in 2024 compared with 2023 and 2022 across all segments.",
        "Net Sales (2024: $249,625; 2023: $237,710; 2022: $222,730) Membership fees (2024: 4,828; 2023: 4,580)",
    ]
    s = BM25(texts).scores("What were net sales in fiscal 2023?")
    assert int(s.argmax()) == 2


def test_hybrid_keeps_the_keyword_best_match_among_four_or_more_excerpts():
    import numpy as np

    class Vec:
        def __init__(self, a):
            self.a = np.asarray(a, dtype="float32")

        def numpy(self):
            return self.a

    texts = ["Plotting a histogram of the data.", "Stem and leaf displays of the data.",
             "Density estimates of the data.", "Quantile plots of the data.",
             "Two sample tests on the data.", "Compare the two samples with boxplot(A, B)."]
    idx = R.LoadedIndex.__new__(R.LoadedIndex)
    idx.ids = [str(i) for i in range(len(texts))]
    idx.chunks = [{"text": t} for t in texts]
    idx.vectors = np.eye(len(texts), dtype="float32")
    idx.weights = np.ones(len(texts), dtype="float32")
    idx.bm25 = R.BM25(texts)
    # the embedding ranks the boxplot chunk last; "data" ties the keyword
    # ranking of the others, so fusion alone leaves the boxplot chunk out
    q = Vec([[0.9, 0.85, 0.8, 0.75, 0.7, 0.1]])
    top = [h["id"] for h in idx.search(q, k=4, queries=["How do I make a boxplot of the data?"])[0]]
    assert "5" in top
    assert "0" in top                       # the embedding's best stays too
    # with k below 4 only the embedding's best is guaranteed
    top3 = [h["id"] for h in idx.search(q, k=3, queries=["How do I make a boxplot of the data?"])[0]]
    assert "0" in top3


def test_extra_chunks_add_what_the_top_k_repeats_leave_out():
    import numpy as np

    class Vec:
        def __init__(self, a):
            self.a = np.asarray(a, dtype="float32")

        def numpy(self):
            return self.a

    def unit(v):
        v = np.asarray(v, dtype="float32")
        return v / np.linalg.norm(v)

    # Six near-copies of one rule, one document that states it differently,
    # and one unrelated chunk.
    vecs = [unit([1, 0.02 * i, 0]) for i in range(6)] + [unit([0.7, 0, 0.71]), unit([0, 1, 0])]
    texts = ["The action level is 15 ppb."] * 6 + ["The trigger is lowered to 0.010 mg/L.", "Board meetings."]
    idx = R.LoadedIndex.__new__(R.LoadedIndex)
    idx.ids = [str(i) for i in range(len(texts))]
    idx.chunks = [{"text": t} for t in texts]
    idx.vectors = np.stack(vecs)
    idx.weights = np.ones(len(texts), dtype="float32")
    idx.bm25 = R.BM25(texts)
    q = Vec([unit([1, 0, 0.3])])
    plain = [h["id"] for h in idx.search(q, k=4, mode="dense")[0]]
    five = [h["id"] for h in idx.search(q, k=5, mode="dense")[0]]
    more = [h["id"] for h in idx.search(q, k=4, mode="dense", extra=1)[0]]
    assert "6" not in plain and "6" not in five       # the copies crowd it out of the top 4 and 5
    assert more[:4] == plain and more[4] == "6"        # the top 4 is unchanged; the different one is added
    assert len(idx.search(q, k=4, mode="dense", extra=2)[0]) == 6
    assert len(idx.search(q, k=4, mode="dense", extra=99)[0]) == len(texts)   # never more than there is


def test_prefixes_follow_how_each_model_was_trained():
    from dragonfarm.retrieval import prefixes
    q, d = prefixes("BAAI/bge-small-en-v1.5")
    assert q.startswith("Represent this sentence") and d == ""
    assert prefixes("intfloat/multilingual-e5-small") == ("query: ", "passage: ")
    assert prefixes("sentence-transformers/all-MiniLM-L6-v2") == ("", "")
