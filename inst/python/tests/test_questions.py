"""Prompt building, parsing, filters, and the filter path for teacher outputs. No model."""

import json
import tempfile
from pathlib import Path

from dragonfarm import questions as Q

CHUNK = {"id": "abc-000", "source": "policy.md", "section": "Returns", "weight": 1.0, "quoted": False, "code": False,
         "text": "Any device can be returned within 30 days of delivery, opened or unopened, for a full refund. "
                 "To start a return, open Orders in your account, pick the order, and choose Start a return. "
                 "Refunds go to the original payment method within 5 business days of the return being scanned in."}


def test_prompt_names_the_source_and_asks_for_n_pairs():
    p = Q.prompt_for(CHUNK, 2)
    assert "policy.md" in p and "Returns" in p and "Write 2 different questions" in p
    assert p.rstrip().endswith("Q1: ...\nA1: ...\nQ2: ...\nA2: ...")


def test_parse_reads_q_a_blocks_and_tolerates_noise():
    out = ("Sure! Here you go.\n\nQ1: How long is the return window?\nA1: Any device can be returned within 30 days "
           "of delivery.\n\nQ2: Where do I start a return?\nA2: Open Orders in your account,\npick the order, and choose "
           "Start a return.\n\nQ3: incomplete")
    pairs = Q.parse(out)
    assert len(pairs) == 2
    assert pairs[1][0] == "Where do I start a return?"
    assert "pick the order" in pairs[1][1] and "\n" not in pairs[1][1]
    assert Q.parse("") == [] and Q.parse("No format at all") == []


def test_filters_keep_grounded_pairs_and_explain_rejections():
    seen = []
    assert Q.judge("How long is the return window?", "Any device can be returned within 30 days of delivery.", CHUNK, seen) is None
    assert Q.judge("How long is the return window?", "You can return it within 30 days.", CHUNK, seen) == "duplicate question"
    assert Q.judge("Where do refunds go after a return?", "Refunds are issued as store credit after 14 days of processing.", CHUNK, []).startswith("answer not grounded")
    assert Q.judge("What does the passage say about returns?", "Thirty days from delivery.", CHUNK, []) == "refers to the passage"
    assert Q.judge("Which function starts a return?", "Call dragon_return() from the account page.", CHUNK, []).startswith("names not in the source")
    assert Q.judge("Returns?", "Within 30 days of delivery, opened or unopened.", CHUNK, []) == "question length"
    assert Q.judge("How long is the return window", "Within 30 days of delivery, opened or unopened.", CHUNK, []) == "not a question"
    assert Q.judge("How long is the return window?", "Yes.", CHUNK, []) == "answer length"


def test_chunk_selection_skips_quotes_and_changelog_by_default():
    chunks = [dict(CHUNK), dict(CHUNK, id="q", quoted=True), dict(CHUNK, id="c", code=True), dict(CHUNK, id="n", weight=0.7)]
    assert [c["id"] for c in Q.select_chunks(chunks)] == ["abc-000", "c"]
    assert [c["id"] for c in Q.select_chunks(chunks, include_quotes=True, include_code=False, include_changelog=True)] == ["abc-000", "q", "n"]
    assert [c["id"] for c in Q.select_chunks(chunks, chunk_ids={"c"})] == ["c"]


def test_filter_outputs_numbers_rows_and_counts_unparsed():
    good = "Q1: How long is the return window?\nA1: Any device can be returned within 30 days of delivery.\nQ2: Where do I start a return?\nA2: Open Orders in your account and choose Start a return."
    rows, unparsed = Q.filter_outputs([CHUNK], [(CHUNK["id"], good), (CHUNK["id"], "garbage")])
    assert unparsed == 1 and [r["id"] for r in rows] == ["p0001", "p0002"]
    assert all(r["keep"] for r in rows) and all(r["reason"] is None for r in rows)
    assert rows[0]["source"] == "policy.md" and rows[0]["decided_by"] == "filter"


def test_filter_subcommand_writes_rows_and_meta():
    with tempfile.TemporaryDirectory() as tmp:
        set_dir = Path(tmp)
        (set_dir / "chunks.jsonl").write_text(json.dumps(CHUNK) + "\n", encoding="utf-8")
        raw = set_dir / "raw.json"
        raw.write_text(json.dumps([{"chunk_id": CHUNK["id"], "output": "Q1: How long is the return window?\nA1: Any device can be returned within 30 days of delivery."}]), encoding="utf-8")
        out = set_dir / "questions" / "x.jsonl"
        out.parent.mkdir()
        Q.main(["filter", "--dir", str(set_dir), "--raw", str(raw), "--out", str(out), "--generator", "claude"])
        rows = [json.loads(l) for l in out.read_text(encoding="utf-8").splitlines()]
        meta = json.loads((set_dir / "questions" / "x.jsonl.meta.json").read_text(encoding="utf-8"))
        assert len(rows) == 1 and rows[0]["keep"] is True
        assert meta["generator"] == "claude" and meta["n_kept"] == 1


def test_prompts_subcommand_lists_selected_chunks():
    import contextlib
    import io

    with tempfile.TemporaryDirectory() as tmp:
        set_dir = Path(tmp)
        (set_dir / "chunks.jsonl").write_text(json.dumps(CHUNK) + "\n" + json.dumps(dict(CHUNK, id="q", quoted=True)) + "\n", encoding="utf-8")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            Q.main(["prompts", "--dir", str(set_dir), "--per-chunk", "2"])
        out = json.loads(buf.getvalue())
        assert [o["chunk_id"] for o in out] == ["abc-000"] and "Write 2 different" in out[0]["prompt"]


def test_mix_asks_for_varied_question_types_only_when_asked():
    from dragonfarm.questions import prompt_for, MIX
    chunk = {"source": "a.pdf", "section": "S", "text": "Some text here."}
    assert MIX not in prompt_for(chunk, 3)
    p = prompt_for(chunk, 3, mix=True)
    assert MIX in p and p.index(MIX) < p.index("Use exactly this format:")
    assert p.endswith("A3: ...")


def test_labels_wrapped_in_markdown_still_parse():
    from dragonfarm.questions import parse
    plain = "Q1: How long is the warranty?\nA1: Two years.\nQ2: Can I return it?\nA2: Within 30 days."
    bold = "**Q1:** How long is the warranty?\n\n**A1:** Two years.\n\n**Q2**: Can I return it?\n**A2**: Within 30 days."
    heads = "### Q1: How long is the warranty?\n### A1: Two years."
    assert parse(plain) == [("How long is the warranty?", "Two years."), ("Can I return it?", "Within 30 days.")]
    assert parse(bold) == parse(plain)
    assert parse(heads) == [("How long is the warranty?", "Two years.")]
