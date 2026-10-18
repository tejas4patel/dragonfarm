# List runs

List runs

## Usage

``` r
dragon_runs(runs_dir = dragon_runs_dir())
```

## Arguments

- runs_dir:

  Directory holding run directories.

## Value

A data frame with one row per run, newest first.

## Examples

``` r
# A folder with no runs yet gives an empty table
dragon_runs(tempdir())
#> [1] id         dir        state      stage      method     model      created_at
#> [8] eval_loss 
#> <0 rows> (or 0-length row.names)
```
