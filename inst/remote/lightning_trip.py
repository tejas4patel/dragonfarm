"""Train a packed dragonfarm run on a Lightning AI Studio and bring the results back.

Run by dragonfarm (lightning_round_trip() in R), not by hand:

    python lightning_trip.py <bundle.zip> <run-dir> [--machine T4] [--max-hours 6]

Needs LIGHTNING_USER_ID and LIGHTNING_API_KEY in the environment. The Studio
is always stopped at the end, even after a failure, so free credits are not
spent on an idle machine. Progress goes to the run's status.json
(remote.stage), where the app shows it.
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path


def set_stage(run_dir, stage, detail=None):
    path = Path(run_dir) / "status.json"
    st = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    remote = st.get("remote") or {}
    remote.update({"provider": "lightning", "stage": stage, "detail": detail,
                   "stage_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    st["remote"] = remote
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(st, indent=2), encoding="utf-8")
    os.replace(tmp, path)
    print(f"[dragonfarm] {stage}" + (f": {detail}" if detail else ""), flush=True)


def commands(zip_name, run_id):
    work = "dragonfarm_work"
    results = f"dragonfarm-results-{run_id}.zip"
    return [
        f"cd dragonfarm && rm -rf {work} && python -c \"import zipfile; zipfile.ZipFile('{zip_name}').extractall('{work}')\"",
        f"cd dragonfarm && python -m pip install -q -r {work}/requirements.txt",
        f"cd dragonfarm && PYTHONPATH={work}/python PYTHONUNBUFFERED=1 python -m dragonfarm.train --run-dir {work}/run",
        f"cd dragonfarm && PYTHONPATH={work}/python python -m dragonfarm.pack_results {work}/run --out . && ls {results}",
    ], results


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("run_dir")
    ap.add_argument("--machine", default="T4")
    ap.add_argument("--max-hours", type=float, default=6)
    a = ap.parse_args(argv)

    from lightning_sdk import Machine, Studio

    run_id = json.loads((Path(a.run_dir) / "config.json").read_text(encoding="utf-8"))["run_id"]
    studio = None
    try:
        set_stage(a.run_dir, "starting")
        studio = Studio(name=f"dragonfarm-{run_id}"[:60], create_ok=True)
        studio.start(getattr(Machine, a.machine), max_runtime=int(a.max_hours * 3600))
        set_stage(a.run_dir, "uploading")
        zip_name = Path(a.bundle).name
        studio.upload_file(a.bundle, f"dragonfarm/{zip_name}", progress_bar=False)
        set_stage(a.run_dir, "running")
        cmds, results = commands(zip_name, run_id)
        for c in cmds:
            print(studio.run(c), flush=True)
        set_stage(a.run_dir, "downloading")
        local = Path(a.run_dir) / "remote" / results
        studio.download_file(f"dragonfarm/{results}", str(local))
        set_stage(a.run_dir, "downloaded", str(local))
        return 0
    except Exception as e:  # report, then stop the machine below
        set_stage(a.run_dir, "failed", f"{type(e).__name__}: {e}")
        return 1
    finally:
        if studio is not None:
            try:
                studio.stop()
            except Exception as e:
                print(f"[dragonfarm] could not stop the Studio: {e}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
