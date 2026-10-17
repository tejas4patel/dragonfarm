"""Error codes: the contract R uses to word messages."""

import tempfile
from pathlib import Path

from dragonfarm import documents as D
from dragonfarm.errors import CODES, DragonError, classify, describe


class RepositoryNotFoundError(Exception):
    """Stands in for huggingface_hub's exception of the same name."""


class GatedRepoError(RepositoryNotFoundError):
    """A gated model exists; it needs a token, which is not 'not found'."""


class OutOfMemoryError(RuntimeError):
    """Stands in for torch.cuda.OutOfMemoryError."""


def test_codes_come_from_the_type_first_then_the_text():
    # transformers wraps the Hub's error in a plain OSError; the cause carries the type
    try:
        try:
            raise RepositoryNotFoundError("404")
        except RepositoryNotFoundError as inner:
            raise OSError("Qwen/x is not a local folder and is not a valid model identifier") from inner
    except OSError as e:
        assert classify(e) == "MODEL_NOT_FOUND"
    assert classify(OSError("nobody/nothing is not a local folder and is not a valid model identifier listed")) == "MODEL_NOT_FOUND"
    assert classify(GatedRepoError("needs a token")) == "UNKNOWN"
    assert classify(OutOfMemoryError("CUDA")) == "OUT_OF_MEMORY"
    assert classify(RuntimeError("CUBLAS_STATUS_EXECUTION_FAILED when calling cublasGemmEx")) == "OUT_OF_MEMORY"
    assert classify(FileNotFoundError("x.pdf")) == "FILE_NOT_FOUND"
    assert classify(ValueError("Unknown column 'reply'")) == "UNKNOWN"
    assert describe(DragonError("NO_TEXT_LAYER", "scan")) == {"error": "DragonError: scan", "code": "NO_TEXT_LAYER"}


def test_dragon_errors_are_value_errors_with_known_codes_only():
    assert isinstance(DragonError("NO_TEXT_LAYER", "x"), ValueError)
    try:
        DragonError("MADE_UP", "x")
        raise AssertionError("an unknown code should be refused")
    except ValueError as e:
        assert "unknown error code" in str(e)
    assert "UNKNOWN" in CODES


def test_a_failed_source_records_its_code():
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "src"
        src.mkdir()
        (src / "notes.doc").write_bytes(b"x")
        (src / "ok.md").write_text("# Returns\n\n" + "Any device can be returned within 30 days. " * 10, encoding="utf-8")
        summary = D.build([str(src / "notes.doc"), str(src / "ok.md")], Path(tmp) / "set", "t", max_words=120, min_words=20)
        failed = {f["name"]: f for f in summary["failed"]}
        assert failed["notes.doc"]["code"] == "UNSUPPORTED_FILE_TYPE"
        assert "save it as .docx" in failed["notes.doc"]["error"]


def test_files_a_folder_holds_that_no_reader_handles_are_listed_not_hidden():
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "src"
        (src / "old").mkdir(parents=True)
        (src / "ok.md").write_text("# Returns\n\n" + "Any device can be returned within 30 days. " * 10, encoding="utf-8")
        (src / "old" / "notes.doc").write_bytes(b"x")
        (src / "deck.pptx").write_bytes(b"x")
        (src / "photo.png").write_bytes(b"x")
        (src / "~$ok.docx").write_bytes(b"x")          # Office lock file: not mentioned
        (src / ".DS_Store").write_bytes(b"x")          # hidden: not mentioned
        summary = D.build([str(src)], Path(tmp) / "set", "t", max_words=120, min_words=20)
        names = {s["name"]: s for s in summary["skipped"]}
        assert set(names) == {"old/notes.doc", "deck.pptx", "photo.png"}
        assert "docx" in names["old/notes.doc"]["hint"] and "PDF" in names["deck.pptx"]["hint"]
        assert names["photo.png"]["hint"] is None and summary["n_chunks"] >= 1


def test_python_codes_are_in_the_shared_list_r_reads():
    import json
    shared = json.loads((Path(__file__).resolve().parents[2] / "tools" / "error_codes.json").read_text(encoding="utf-8"))
    assert set(CODES) <= set(shared)


def test_tools_reach_the_chat_template_only_when_given():
    from dragonfarm.data import render_prompt

    class Tok:
        chat_template = "{{ messages }}"

        def __init__(self):
            self.calls = []

        def apply_chat_template(self, messages, **kw):
            self.calls.append(kw)
            return "prompt"

    tok = Tok()
    render_prompt(tok, [{"role": "user", "content": "hi"}])
    spec = [{"type": "function", "function": {"name": "list_runs", "parameters": {"type": "object", "properties": {}}}}]
    render_prompt(tok, [{"role": "user", "content": "hi"}], tools=spec)
    assert "tools" not in tok.calls[0]
    assert tok.calls[1]["tools"] == spec and tok.calls[1]["add_generation_prompt"] is True


def test_a_model_with_only_pickle_weights_gets_its_own_code():
    err = OSError("Qwen/x does not appear to have a file named model.safetensors or model.safetensors.index.json")
    assert classify(err) == "PICKLE_WEIGHTS_ONLY"
