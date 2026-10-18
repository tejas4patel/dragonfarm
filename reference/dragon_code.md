# R code that reproduces a run

Every run, including ones started from the Shiny app, can be replayed as
a script. The dataset path is the original source when it was a file. A
run that continued from an earlier run refers to that run by directory.

## Usage

``` r
dragon_code(run)
```

## Arguments

- run:

  A `dragon_run` or run directory.

## Value

A single string of R code.

## Examples

``` r
if (interactive()) {
run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))
cat(dragon_code(run))
}
```
