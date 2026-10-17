import json
import tempfile
from pathlib import Path

from dragonfarm.resume import latest_checkpoint, trim_progress


def _checkpoint(root, step, state=True, text=None):
    p = root / "checkpoints" / f"checkpoint-{step}"
    p.mkdir(parents=True)
    (p / "adapter_model.safetensors").write_bytes(b"x")
    if state:
        (p / "trainer_state.json").write_text(text if text is not None else json.dumps({"global_step": step}),
                                             encoding="utf-8")
    return p


def test_no_checkpoints_folder_gives_none():
    with tempfile.TemporaryDirectory() as d:
        assert latest_checkpoint(Path(d)) is None


def test_newest_complete_checkpoint_wins_by_number_not_name():
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        _checkpoint(root, 9)
        _checkpoint(root, 10)
        assert latest_checkpoint(root).name == "checkpoint-10"


def test_checkpoint_interrupted_while_saving_is_skipped():
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        _checkpoint(root, 10)
        _checkpoint(root, 20, state=False)              # killed before the state file
        _checkpoint(root, 30, text='{"global_step": 3')  # killed while writing it
        assert latest_checkpoint(root).name == "checkpoint-10"


def test_only_incomplete_checkpoints_gives_none():
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        _checkpoint(root, 20, state=False)
        (root / "checkpoints" / "checkpoint-tmp").mkdir()
        assert latest_checkpoint(root) is None


def test_progress_after_the_checkpoint_is_dropped_on_resume():
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        rows = [{"step": s, "loss": 1.0} for s in (1, 5, 10, 15)] + [{"note": "no step"}]
        text = "".join(json.dumps(r) + "\n" for r in rows) + '{"step": 20, "lo'   # cut short by the crash
        (root / "progress.jsonl").write_text(text, encoding="utf-8")
        assert trim_progress(root, 10) == 2
        kept = [json.loads(l) for l in (root / "progress.jsonl").read_text(encoding="utf-8").splitlines()]
        assert [r.get("step") for r in kept] == [1, 5, 10, None]
        assert trim_progress(root / "missing", 10) == 0


def test_reinforce_checkpoint_round_trip_restores_weights_and_optimizer():
    import torch
    from peft import LoraConfig, get_peft_model
    from dragonfarm.resume import restore_reinforce_checkpoint, save_reinforce_checkpoint

    def tiny():
        torch.manual_seed(0)
        base = torch.nn.Sequential(torch.nn.Linear(8, 8), torch.nn.ReLU(), torch.nn.Linear(8, 2))
        return get_peft_model(base, LoraConfig(r=2, target_modules=["0", "2"], init_lora_weights=False))

    def lora(m):
        return {k: v.detach().clone() for k, v in m.named_parameters() if "lora_" in k}

    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        model = tiny()
        opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=1e-2)
        for _ in range(3):
            opt.zero_grad()
            model(torch.randn(4, 8)).sum().backward()
            opt.step()
        ckpt = save_reinforce_checkpoint(model, opt, root, 3)
        assert latest_checkpoint(root) == ckpt
        assert json.loads((root / "checkpoints" / "reinforce_state.json").read_text())["step"] == 3

        fresh = tiny()
        fresh_opt = torch.optim.AdamW([p for p in fresh.parameters() if p.requires_grad], lr=1e-2)
        assert any(not torch.equal(a, b) for a, b in zip(lora(model).values(), lora(fresh).values()))
        assert restore_reinforce_checkpoint(fresh, fresh_opt, ckpt) is True
        for k, v in lora(model).items():
            assert torch.equal(v, lora(fresh)[k]), k
        saved = opt.state_dict()["state"]
        restored = fresh_opt.state_dict()["state"]
        assert set(saved) == set(restored)
        for i in saved:
            assert torch.equal(saved[i]["exp_avg"], restored[i]["exp_avg"])
