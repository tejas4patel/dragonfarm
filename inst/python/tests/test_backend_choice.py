"""Which trainer a run uses (D-35): Unsloth where it can, the standard one otherwise."""

import os

from dragonfarm.backend import choose, wanted


def cfg(**train):
    return {"model": {"id": "m"}, "train": dict(train)}


def ok():
    return None


def test_unsloth_when_installed_with_a_gpu():
    assert choose(cfg(), "sft", cuda_available=True, unsloth_installed=True, start=ok) == ("unsloth", None)


def test_the_standard_trainer_otherwise_and_it_says_why():
    lib, why = choose(cfg(), "sft", cuda_available=False, unsloth_installed=True, start=ok)
    assert lib == "transformers" and "NVIDIA" in why
    lib, why = choose(cfg(), "sft", cuda_available=True, unsloth_installed=False, start=ok)
    assert lib == "transformers" and "not installed" in why
    lib, why = choose(cfg(), "distil", cuda_available=True, unsloth_installed=True, start=ok)
    assert lib == "transformers" and "distil" in why                 # a stage not (yet) on Unsloth
    assert choose(cfg(), "prefer", cuda_available=True, unsloth_installed=True, start=ok)[0] == "transformers"
    assert choose(cfg(), "reinforce", cuda_available=True, unsloth_installed=True, start=ok)[0] == "unsloth"
    c = cfg(); c["model"]["base_adapters"] = ["base_adapters/1"]      # a run that continues an earlier one
    assert choose(c, "sft", cuda_available=True, unsloth_installed=True, start=ok)[0] == "unsloth"
    c["train"]["backend"] = "transformers"
    assert choose(c, "sft", cuda_available=True, unsloth_installed=True, start=ok)[0] == "transformers"


def test_a_failed_start_falls_back_with_the_error():
    lib, why = choose(cfg(), "sft", cuda_available=True, unsloth_installed=True, start=lambda: "ImportError: triton")
    assert lib == "transformers" and "triton" in why


def test_the_choice_can_be_forced():
    assert choose(cfg(backend="transformers"), "sft", cuda_available=True, unsloth_installed=True, start=ok)[0] == "transformers"
    old = os.environ.get("DRAGONFARM_TRAIN_BACKEND")
    os.environ["DRAGONFARM_TRAIN_BACKEND"] = "transformers"
    try:
        assert wanted(cfg()) == "transformers"
        assert wanted(cfg(backend="unsloth")) == "unsloth"      # the run's own setting wins
    finally:
        if old is None:
            del os.environ["DRAGONFARM_TRAIN_BACKEND"]
        else:
            os.environ["DRAGONFARM_TRAIN_BACKEND"] = old
    assert wanted(cfg(backend="nonsense")) == "auto"


def test_answering_uses_unsloth_where_it_can_and_says_why_not_otherwise():
    from dragonfarm.backend import choose_inference
    assert choose_inference({}, cuda_available=True, unsloth_installed=True, start=ok) == ("unsloth", None)
    assert choose_inference({}, cuda_available=False, unsloth_installed=True, start=ok)[0] == "transformers"
    assert choose_inference({"base_adapters": ["a"]}, cuda_available=True, unsloth_installed=True, start=ok)[0] == "transformers"
    assert choose_inference({"allow_pickle": True}, cuda_available=True, unsloth_installed=True, start=ok)[0] == "transformers"
    old = os.environ.get("DRAGONFARM_INFER_BACKEND")
    os.environ["DRAGONFARM_INFER_BACKEND"] = "transformers"
    try:
        assert choose_inference({}, cuda_available=True, unsloth_installed=True, start=ok)[0] == "transformers"
    finally:
        if old is None:
            del os.environ["DRAGONFARM_INFER_BACKEND"]
        else:
            os.environ["DRAGONFARM_INFER_BACKEND"] = old
