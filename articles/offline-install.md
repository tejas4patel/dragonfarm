# Install without the internet

On a laptop, dragonfarm builds its own Python environment the first time
it runs. A server behind a firewall can’t, and a team often wants every
machine to be exactly the same. For both, dragonfarm ships a lock: every
Python package it needs, pinned to one version, with hashes, for
Windows, macOS and Linux. This page is for the person who sets machines
up.

The environment a laptop builds for itself uses the same pinned
versions, so it matches a server’s and does not change when new releases
appear. Set `DRAGONFARM_PYTHON_LOCKED=false` for the newest releases
instead.

You need [uv](https://docs.astral.sh/uv/) and Python 3.12 or later on
each machine. The lock comes with the package:

``` r

system.file("python", "requirements.lock", package = "dragonfarm")
```

## Same packages everywhere

On a machine with the internet, build the environment from the lock:

``` sh
uv venv /opt/dragonfarm-py --python 3.12
uv pip sync requirements.lock --python /opt/dragonfarm-py --require-hashes
```

Then tell dragonfarm to use it, for example in the server’s `.Renviron`:

``` sh
DRAGONFARM_PYTHON=/opt/dragonfarm-py/bin/python
```

(On Windows the interpreter is `Scripts\python.exe` inside the folder.)

## No internet at all

On a machine that has the internet and the same operating system as the
target, download the packages into a folder:

``` sh
uv venv dl --python 3.12 --seed
dl/bin/python -m pip download -r requirements.lock --require-hashes --only-binary=:all: -d wheels
```

Copy `wheels` and `requirements.lock` across, then build with no index:

``` sh
uv venv /opt/dragonfarm-py --python 3.12
uv pip sync requirements.lock --python /opt/dragonfarm-py --require-hashes --offline --no-index --find-links wheels
```

On Windows this was about 210 MB of packages. Built this way with an
empty cache and no network, the environment came out identical to one
built online.

Models come from Hugging Face. Download them on a connected machine,
copy the Hugging Face cache folder across, and set `HF_HUB_OFFLINE=1`.
Presets are pinned to exact model versions, so every machine loads the
same weights.

## Check a machine

``` r

dragon_check()
```

When `DRAGONFARM_PYTHON` is set, the check compares the environment with
the lock and names any package that differs.

## GPUs

The lock is resolved from PyPI. On Windows that gives the CPU build of
torch; on Linux, PyPI’s torch already includes CUDA. For a Windows
server with an NVIDIA card, add the CUDA build from the PyTorch package
index when you download.

## One catalogue for the team

Each runs folder keeps a small record of what happened: answers and
where they came from, approvals, policies, model versions and who signed
them off. On a laptop that is a file in the folder. For a team, point
everyone at one Postgres database instead, for example in the server’s
`.Renviron`:

``` sh
DRAGONFARM_CATALOG=postgresql://dragonfarm:PASSWORD@db.example.com:5432/dragonfarm
```

The tables are created on first use, and the record stays append-only:
the database itself refuses to change or delete past entries. You need
the RPostgres package installed.
