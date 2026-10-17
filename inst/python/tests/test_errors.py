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
