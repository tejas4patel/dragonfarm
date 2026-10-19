# Running dragonfarm with Docker (draft)

**Status: draft, not yet built or run.** Written on 2026-10-18 without a
machine that has Docker. Until it has been tested, treat it as a starting
point, not a supported install. Posit Connect with a shared Postgres
catalogue remains the main route for teams.

## What it starts

- `db`: Postgres 16, holding the shared catalogue (records, policies,
  model versions, sign-offs).
- `app`: the dragonfarm app on port 3838, bound to this machine only.
  Runs and document sets go in the `runs` volume; the Python environment is
  built from the package's lock on first use and kept in the `python`
  volume (2 to 3 GB, several minutes the first time).

With a shared catalogue, governed mode and four-eyes sign-off are on by
default.

## Start it

1. Next to `docker-compose.yml`, create a file `.env` with one line:
   `DRAGONFARM_DB_PASSWORD=` followed by a password of your choice. Keep the
   file out of version control.
2. On a machine with an NVIDIA GPU and the NVIDIA Container Toolkit,
   uncomment the `deploy:` block. Without it, the app runs on the CPU
   (small models only).
3. Run `docker compose up -d` in this folder, then open
   <http://127.0.0.1:3838>.

## Before a team uses it

- The app has no sign-in of its own. Put it behind your organisation's
  sign-in (for example a reverse proxy), or use Posit Connect, which signs
  people in and passes their name to the app.
- Name the policy admins in Settings before others can reach the app.
- Back up the `catalogue` volume: it is the record.

## To check once Docker is available

- [ ] `docker compose build` succeeds
- [ ] The app opens and `dragon_check()` builds the Python environment
- [ ] The catalogue is Postgres (Monitor shows records; a policy saved in
      Settings survives a restart)
- [ ] With the GPU block on, a small run trains on the GPU
