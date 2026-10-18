"""lightning_trip.py against a fake lightning_sdk: the stages it writes, the
commands it runs, and that the Studio is always stopped."""
import importlib.util
import json
import sys
import tempfile
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent.parent / "remote" / "lightning_trip.py"


def load_with_fake_sdk(fail_at=None):
    calls = []

    class Machine:
        T4 = "T4"

    class Studio:
        def __init__(self, name=None, create_ok=True, **kw):
            calls.append(("init", name))

        def start(self, machine=None, max_runtime=None):
            calls.append(("start", machine, max_runtime))
            if fail_at == "start":
                raise RuntimeError("no T4 available")

        def upload_file(self, file_path, remote_path=None, progress_bar=True):
            calls.append(("upload", remote_path))

        def run(self, *commands):
            calls.append(("run", commands[0]))
            if fail_at == "run":
                raise RuntimeError("training failed")
            return "ok"

        def download_file(self, remote_path, file_path=None):
            calls.append(("download", remote_path))
            Path(file_path).write_text("zip")

        def stop(self):
            calls.append(("stop",))

    sdk = types.ModuleType("lightning_sdk")
    sdk.Machine, sdk.Studio = Machine, Studio
    sys.modules["lightning_sdk"] = sdk
    spec = importlib.util.spec_from_file_location("lightning_trip", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod, calls


def make_run(d):
    run = Path(d) / "20261017-r1"
    (run / "remote").mkdir(parents=True)
    (run / "config.json").write_text(json.dumps({"run_id": "20261017-r1"}))
    (run / "status.json").write_text(json.dumps({"state": "bundled"}))
    zipf = run / "remote" / "dragonfarm-20261017-r1.zip"
    zipf.write_text("zip")
    return run, zipf


def test_round_trip_downloads_results_and_stops_the_studio():
    mod, calls = load_with_fake_sdk()
    with tempfile.TemporaryDirectory() as d:
        run, zipf = make_run(d)
        assert mod.main([str(zipf), str(run), "--max-hours", "2"]) == 0
        st = json.loads((run / "status.json").read_text())["remote"]
        assert st["stage"] == "downloaded" and st["provider"] == "lightning"
        assert Path(st["detail"]).exists()
        kinds = [c[0] for c in calls]
        assert kinds[:3] == ["init", "start", "upload"] and kinds[-1] == "stop"
        assert ("start", "T4", 7200) in calls
        runs = [c[1] for c in calls if c[0] == "run"]
        assert any("dragonfarm.train" in r for r in runs) and any("pack_results" in r for r in runs)


def test_a_failure_is_reported_and_the_studio_still_stops():
    for where in ("start", "run"):
        mod, calls = load_with_fake_sdk(fail_at=where)
        with tempfile.TemporaryDirectory() as d:
            run, zipf = make_run(d)
            assert mod.main([str(zipf), str(run)]) == 1
            st = json.loads((run / "status.json").read_text())["remote"]
            assert st["stage"] == "failed"
            assert calls[-1] == ("stop",)
