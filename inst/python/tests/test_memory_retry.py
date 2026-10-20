"""Running out of GPU memory once: the trainer tries again with safer settings."""

import json
import tempfile
from pathlib import Path

import dragonfarm.train as tr


def make_run(batch=4, accum=4, ckpt=False):
    d = Path(tempfile.mkdtemp())
    cfg = {"stage": "sft", "train": {"per_device_batch_size": batch, "gradient_accumulation": accum,
                                     "gradient_checkpointing": ckpt, "epochs": 1}}
    (d / "config.json").write_text(json.dumps(cfg), encoding="utf-8")
    return d


def read_cfg(d):
    return json.loads((d / "config.json").read_text(encoding="utf-8"))


def test_safer_settings_keep_the_effective_batch_and_are_written_to_the_run():
    d = make_run(batch=4, accum=4)
    change = tr.memory_safer(d)
    t = read_cfg(d)["train"]
    assert (t["per_device_batch_size"], t["gradient_accumulation"], t["gradient_checkpointing"]) == (1, 16, True)
    assert change["from"]["per_device_batch_size"] == 4 and change["to"]["gradient_accumulation"] == 16


def test_nothing_left_to_lower_means_no_retry():
    d = make_run(batch=1, accum=16, ckpt=True)
    assert tr.memory_safer(d) is None
    assert read_cfg(d)["train"]["gradient_accumulation"] == 16


def run_main(d, outcomes):
    """Run main() with train() replaced by a script of outcomes."""
    calls = []
    real = tr.train

    def fake_train(run_dir, status, resume):
        calls.append(read_cfg(run_dir)["train"])
        out = outcomes[len(calls) - 1]
        if isinstance(out, Exception):
            raise out
        return out

    tr.train = fake_train
    try:
        try:
            tr.main(["--run-dir", str(d)])
        except SystemExit as e:
            code = e.code
    finally:
        tr.train = real
    status = json.loads((d / "status.json").read_text(encoding="utf-8"))
    return code, calls, status


def test_out_of_memory_once_trains_again_with_safer_settings():
    d = make_run(batch=4, accum=4)
    code, calls, status = run_main(d, [RuntimeError("CUDA out of memory. Tried to allocate 70.00 MiB"), "succeeded"])
    assert code == 0 and status["state"] == "succeeded"
    assert len(calls) == 2 and calls[1]["per_device_batch_size"] == 1 and calls[1]["gradient_checkpointing"]
    assert status["memory_retry"]["to"]["gradient_accumulation"] == 16


def test_out_of_memory_twice_fails_with_the_hint():
    d = make_run(batch=4, accum=4)
    oom = RuntimeError("CUDA out of memory. Tried to allocate 70.00 MiB")
    code, calls, status = run_main(d, [oom, oom])
    assert code == 1 and status["state"] == "failed" and status["error_code"] == "OUT_OF_MEMORY"
    assert len(calls) == 2 and "batch size 1" in status["error"]


def test_other_errors_are_not_retried():
    d = make_run(batch=4, accum=4)
    code, calls, status = run_main(d, [ValueError("Unknown column 'reply'")])
    assert code == 1 and len(calls) == 1 and "memory_retry" not in status
    assert read_cfg(d)["train"]["per_device_batch_size"] == 4


class AcceleratorError(RuntimeError):
    pass


def test_a_sticky_cuda_error_is_not_retried_and_the_settings_stay():
    d = make_run(batch=4, accum=4)
    sticky = AcceleratorError("CUDA error: out of memory. Sticky error detected")
    code, calls, status = run_main(d, [sticky])
    assert code == 1 and len(calls) == 1 and status["error_code"] == "OUT_OF_MEMORY"
    assert "memory_retry" not in status
    assert read_cfg(d)["train"]["per_device_batch_size"] == 4


def test_which_out_of_memory_errors_can_be_retried():
    class OutOfMemoryError(RuntimeError):
        pass
    assert tr.recoverable_oom(OutOfMemoryError("CUDA out of memory. Tried to allocate 70.00 MiB"))
    assert tr.recoverable_oom(RuntimeError("CUDA out of memory. Tried to allocate 2.00 GiB"))
    assert not tr.recoverable_oom(AcceleratorError("CUDA error: out of memory"))
    assert not tr.recoverable_oom(RuntimeError("CUBLAS_STATUS_ALLOC_FAILED"))
    assert not tr.recoverable_oom(ValueError("no"))
