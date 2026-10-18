# Archive, restore, or delete a run

Archiving moves a run's directory under `archived/` in `runs_dir`. It
disappears from
[`dragon_runs()`](https://dragonfarm.dev/reference/dragon_runs.md) and
the app's Runs list, but every file is kept; `dragon_unarchive_run()`
moves it back exactly as it was. Deleting removes the run directory for
good. Both refuse a run that is queued or running (cancel it first) and
a run that another run continues from, unless `force = TRUE`.

## Usage

``` r
dragon_archive_run(run, runs_dir = dragon_runs_dir(), force = FALSE)

dragon_unarchive_run(id, runs_dir = dragon_runs_dir())

dragon_delete_run(run, runs_dir = dragon_runs_dir(), force = FALSE)
```

## Arguments

- run:

  A `dragon_run`, run directory, or run id (with `runs_dir`).

- runs_dir:

  Where runs live. Needed only when `run`/`id` is a bare id.

- force:

  Archive or delete even if another run continues from this one.

- id:

  An archived run's id, for `dragon_unarchive_run()`.

## Value

The run id, invisibly.

## Examples

``` r
if (interactive()) {
run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))
dragon_archive_run(run)
dragon_archived_runs()
dragon_unarchive_run(run$id)
# dragon_delete_run(run) removes it for good
}
```
