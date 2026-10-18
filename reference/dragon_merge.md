# Merge the adapter into the base model

Produces a standalone model directory that loads with plain transformers
and needs neither peft nor dragonfarm.

## Usage

``` r
dragon_merge(run, out_dir = NULL)
```

## Arguments

- run:

  A `dragon_run` or run directory.

- out_dir:

  Where to write the merged model. Defaults to `merged/` inside the run
  directory.

## Value

The output path, invisibly.

## Examples

``` r
if (interactive()) {
run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))
dir <- dragon_merge(run)
}
```
