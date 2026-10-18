# Resume a run from its latest checkpoint

Useful after a cancel or a crash. Continues with the same configuration.

## Usage

``` r
dragon_resume(run, wait = FALSE)
```

## Arguments

- run:

  A `dragon_run`.

- wait:

  Block until training finishes.

## Value

A `dragon_run` object.

## Examples

``` r
if (interactive()) {
# A run that was cancelled or stopped carries on from its last checkpoint
run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))
dragon_resume(run)
}
```
