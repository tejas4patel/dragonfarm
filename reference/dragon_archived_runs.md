# Archived runs

Runs that
[`dragon_archive_run()`](https://dragonfarm.dev/reference/dragon_archive_run.md)
moved out of the way. Same columns as
[`dragon_runs()`](https://dragonfarm.dev/reference/dragon_runs.md).

## Usage

``` r
dragon_archived_runs(runs_dir = dragon_runs_dir())
```

## Arguments

- runs_dir:

  Where runs live.

## Value

A data frame, one row per archived run.

## Examples

``` r
dragon_archived_runs(tempdir())
#> [1] id         dir        state      stage      method     model      created_at
#> [8] eval_loss 
#> <0 rows> (or 0-length row.names)
```
