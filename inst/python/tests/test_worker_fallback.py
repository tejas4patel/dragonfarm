"""Answering falls back to today's loader when Unsloth fails mid-request, and
Unsloth is given the model's own context length."""

import json
import os
import tempfile

import dragonfarm.backend as be
import dragonfarm.worker as w


class Model:
    def __init__(self, unsloth):
        self._dragonfarm_unsloth = unsloth


class Cache:
    hw = None

    def __init__(self):
        self.dropped = []
        self.loads = 0

    def get(self, req):
        self.loads += 1
        return "tok", Model(unsloth=not self.dropped)

    def drop_unsloth(self, req, err):
        self.dropped.append(str(err))


def fake_generate(tok, model, hw, req):
    if model._dragonfarm_unsloth:
        raise RuntimeError("The size of tensor a (8192) must match the size of tensor b (12025)")
    return {"ok": True, "outputs": ["fine"]}


def test_a_failed_unsloth_answer_is_answered_again_with_the_standard_loader():
    old = w.run_generate
    w.run_generate = fake_generate
    try:
        c = Cache()
        assert w.answer(c, {"model": "m"}) == {"ok": True, "outputs": ["fine"]}
        assert c.loads == 2 and "8192" in c.dropped[0]
    finally:
        w.run_generate = old


def test_no_second_try_after_tokens_were_sent_or_for_the_standard_loader():
    def streamed_then_failed(tok, model, hw, req):
        e = RuntimeError("boom")
        e.dragonfarm_tokens_sent = 3
        raise e

    old = w.run_generate
    try:
        for gen in (streamed_then_failed,):
            w.run_generate = gen
            c = Cache()
            try:
                w.answer(c, {"model": "m"})
                raise AssertionError("expected the error")
            except RuntimeError as e:
                assert str(e) == "boom" and c.loads == 1
        w.run_generate = lambda *a: (_ for _ in ()).throw(ValueError("standard failed"))
        c = Cache(); c.dropped = ["already"]
        try:
            w.answer(c, {"model": "m"})
            raise AssertionError("expected the error")
        except ValueError:
            assert c.loads == 1
    finally:
        w.run_generate = old


def test_after_a_failure_the_cache_chooses_the_standard_loader_and_says_why():
    old = be.choose_inference
    be.choose_inference = lambda req: ("unsloth", None)
    try:
        c = w.ModelCache()
        assert c.backend({"model": "m"}) == ("unsloth", None)
        c.drop_unsloth({"model": "m"}, RuntimeError("bad shape"))
        lib, why = c.backend({"model": "m"})
        assert lib == "transformers" and "bad shape" in why
        assert c.backend({"model": "other"}) == ("unsloth", None)
    finally:
        be.choose_inference = old


def test_unsloth_gets_the_models_own_context_length():
    d = tempfile.mkdtemp()
    with open(os.path.join(d, "config.json"), "w") as f:
        json.dump({"model_type": "qwen2", "max_position_embeddings": 32768}, f)
    assert be.context_length(d) == 32768
    assert be.context_length(os.path.join(d, "missing"), fallback=4096) == 4096
