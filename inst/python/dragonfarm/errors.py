"""Typed error codes shared with R.

Python names what went wrong, where the exception object is still at hand;
R turns the code into the message people read (R/errors.R). The codes are
part of the contract between the two sides: add one here and there together.
"""

CODES = (
    "MODEL_NOT_FOUND",              # no folder by that name and no such model on the Hub
    "OUT_OF_MEMORY",                # the GPU (or CPU) ran out of memory
    "NO_TEXT_LAYER",                # a PDF with no text: a scan or photos of pages
    "PASSWORD_PROTECTED",           # a PDF that needs a password to open
    "ENCRYPTED_NEEDS_CRYPTOGRAPHY",  # an AES-encrypted PDF and no `cryptography` package
    "UNSUPPORTED_FILE_TYPE",        # a file type no reader handles
    "FILE_NOT_FOUND",               # a path that does not exist
    "FETCH_FAILED",                 # a URL that could not be fetched
    "UNKNOWN",
)


class DragonError(ValueError):
    """An error with a code R can turn into a plain message. A ValueError, so
    callers that already catch bad input keep working."""

    def __init__(self, code, message):
        if code not in CODES:
            raise ValueError(f"unknown error code {code!r}")
        super().__init__(message)
        self.code = code


# Errors that mean the GPU ran out of memory. A 7B in 4-bit at batch size 4 on
# an 8 GB laptop card failed with CUBLAS_STATUS_EXECUTION_FAILED rather than
# an out-of-memory error, so these count too.
MEMORY_SIGNS = ("outofmemoryerror", "out of memory", "cublas_status_execution_failed", "cublas_status_alloc_failed",
                "cudnn_status_alloc_failed", "cudnn_status_execution_failed")


def _chain(err):
    seen = []
    while err is not None and err not in seen:
        seen.append(err)
        err = err.__cause__ or err.__context__
    return seen


def classify(err):
    """The code for an exception: its own code, else one recognised from its
    type (anywhere in its cause chain), else from its text."""
    if isinstance(err, DragonError):
        return err.code
    for e in _chain(err):
        name = type(e).__name__
        if isinstance(e, DragonError):
            return e.code
        if name == "RepositoryNotFoundError":   # not its subclass GatedRepoError: that one exists, it needs a token
            return "MODEL_NOT_FOUND"
        if name == "OutOfMemoryError":
            return "OUT_OF_MEMORY"
        if name in ("HTTPError", "URLError"):
            return "FETCH_FAILED"
        if isinstance(e, FileNotFoundError):
            return "FILE_NOT_FOUND"
    text = f"{type(err).__name__} {err}".lower()
    if "is not a local folder and is not a valid model identifier" in text:
        return "MODEL_NOT_FOUND"
    if any(s in text for s in MEMORY_SIGNS):
        return "OUT_OF_MEMORY"
    return "UNKNOWN"


def describe(err):
    """{"error": "<Type>: <message>", "code": "<CODE>"} for a reply or a status file."""
    return {"error": f"{type(err).__name__}: {err}", "code": classify(err)}
