"""GRPO samples through vLLM only when asked (until its A/B), on Linux, with vLLM installed."""

import os

from dragonfarm.backend import choose_vllm
from dragonfarm.reinforce import cut_completion


def with_env(value, fn):
    old = os.environ.get("DRAGONFARM_VLLM")
    if value is None:
        os.environ.pop("DRAGONFARM_VLLM", None)
    else:
        os.environ["DRAGONFARM_VLLM"] = value
    try:
        return fn()
    finally:
        if old is None:
            os.environ.pop("DRAGONFARM_VLLM", None)
        else:
            os.environ["DRAGONFARM_VLLM"] = old


def test_vllm_is_used_only_when_asked_on_linux_with_vllm():
    assert with_env(None, lambda: choose_vllm({}, "reinforce", "linux", True)) == (False, None)
    assert with_env("1", lambda: choose_vllm({}, "reinforce", "linux", True)) == (True, None)
    use, why = with_env("1", lambda: choose_vllm({}, "reinforce", "win32", True))
    assert not use and "Linux" in why
    use, why = with_env("1", lambda: choose_vllm({}, "reinforce", "linux", False))
    assert not use and "not installed" in why
    assert with_env("1", lambda: choose_vllm({}, "sft", "linux", True)) == (False, None)    # GRPO only
    use, why = with_env("0", lambda: choose_vllm({}, "reinforce", "linux", True))
    assert not use and "off" in why


def test_completions_end_at_eos_and_lose_padding():
    assert cut_completion([5, 6, 2, 9, 9], eos_id=2, pad_id=0) == [5, 6, 2]
    assert cut_completion([5, 6, 0, 0], eos_id=2, pad_id=0) == [5, 6]
    assert cut_completion([5, 6], eos_id=2, pad_id=0, stopped=True) == [5, 6, 2]    # vLLM left the stop token out
    assert cut_completion([5, 2], eos_id=2, pad_id=2) == [5, 2]                     # pad and EOS the same token
