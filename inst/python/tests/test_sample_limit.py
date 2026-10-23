"""End-of-training samples respect an Unsloth model's sequence limit, and a
failed sample step is a warning, not a failed run."""

from dragonfarm.evaluate_utils import evaluate_or_warn, fits_limit, sample_generations


class Tok:
    pad_token_id = 0

    def __call__(self, text, **kw):
        return {"input_ids": list(range(len(text.split())))}      # one token per word

    def apply_chat_template(self, messages, **kw):
        return " ".join(m["content"] for m in messages)


class Model:
    def __init__(self, limit=None):
        if limit:
            self.max_seq_length = limit


class Status:
    def __init__(self):
        self.fields = {}

    def update(self, **kw):
        self.fields.update(kw)


def test_prompts_over_the_limit_are_left_out_of_the_samples(monkeypatch=None):
    import dragonfarm.evaluate_utils as eu

    eu.render_prompt = lambda tok, messages, tools=None: tok.apply_chat_template(messages)
    eu.generate_replies = lambda model, tok, prompts, device, **kw: ["r"] * len(prompts)
    short = {"messages": [{"role": "user", "content": "two words"}, {"role": "assistant", "content": "x"}]}
    long = {"messages": [{"role": "user", "content": " ".join(["w"] * 40)}, {"role": "assistant", "content": "x"}]}
    assert fits_limit(Model(), Tok(), long["messages"][:-1], 10)              # no limit: fits
    assert not fits_limit(Model(limit=30), Tok(), long["messages"][:-1], 10)   # 40 + 10 > 30
    out = sample_generations(Model(limit=30), Tok(), [long, short, long], "cpu", n=5, max_new_tokens=10)
    assert len(out) == 1 and out[0]["prompt"] == "two words"


def test_a_broken_sample_step_is_a_warning_when_not_fatal():
    st = Status()
    assert evaluate_or_warn(st, "Sample generation", lambda: 1 / 0, fatal=False) is None
    assert "Sample generation skipped" in st.fields["eval_warning"]
    try:
        evaluate_or_warn(st, "Held-out evaluation", lambda: 1 / 0)
        raise AssertionError("expected the error")
    except ZeroDivisionError:
        pass
