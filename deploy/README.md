# Running dragonfarm with Docker

Tested on 2026-10-19 on Windows 11 with Docker Desktop 4.96 (WSL 2) and an
RTX 4060 laptop GPU: the image builds, the app opens, the shared catalogue is
Postgres and survives a restart, and a small run trains on the GPU inside
the container. Not yet tested: Linux hosts, a team behind a sign-in proxy.
Posit Connect with a shared Postgres catalogue remains the main route for
teams.

## What it starts

- `db`: Postgres 16, holding the shared catalogue (records, policies,
  model versions, sign-offs).
- `app`: the dragonfarm app on port 3838, bound to this machine only.
  Runs and document sets go in the `runs` volume; the Python environment is
  built from the package's lock on first use and kept in the `python`
  volume (about 7 minutes and a few GB the first time).

With a shared catalogue, governed mode and four-eyes sign-off are on by
default.

## Start it

1. Next to `docker-compose.yml`, create a file `.env` with one line:
   `DRAGONFARM_DB_PASSWORD=` followed by a password of your choice. Keep the
   file out of version control.
2. Run `docker compose up -d` in this folder, then open
   <http://127.0.0.1:3838>.
3. With an NVIDIA GPU, add the GPU file instead:
   `docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d`.
   It needs a driver with container support (Docker Desktop with WSL 2 on
   Windows, or the NVIDIA Container Toolkit on Linux). Without it the app
   runs on the CPU (small models only).

The first build takes about a minute: R packages come ready-built.

## Before a team uses it

- The app has no sign-in of its own. Put it behind your organisation's
  sign-in (for example a reverse proxy), or use Posit Connect, which signs
  people in and passes their name to the app.
- Name the policy admins in Settings before others can reach the app.
- Back up the `catalogue` volume: it is the record.
- This setup connects the app as the database owner, which could switch off
  the record's append-only protection. For a validated setup, use two roles
  as described in the "For IT and quality" article (Two database roles).

## What was checked (2026-10-19)

- [x] `docker compose build` succeeds (58 s; it stops if a package fails to
      install)
- [x] The app opens on <http://127.0.0.1:3838>
- [x] The catalogue is Postgres (all 8 tables), and governed mode is on
- [x] A policy saved in the app survives `docker compose down` and `up`
- [x] `dragon_check()` builds the Python environment from the lock (6.9 min)
      and sees the GPU
- [x] With the GPU file, a small run (SmolLM2-135M, example data) trains on
      `cuda:0` and succeeds
- [ ] A Linux host
- [ ] A team behind a sign-in proxy
