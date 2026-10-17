# Directory where runs are stored

Every function that writes a run
([`dragon_train()`](https://dragonfarm.dev/reference/dragon_train.md),
[`dragon_bundle()`](https://dragonfarm.dev/reference/dragon_bundle.md),
the app, and so on) takes a `runs_dir` argument that defaults to this.
Without configuration it resolves to a `dragonfarm_runs` folder under a
session temp directory, so a fresh R session never writes to your
working directory or home filespace by default; that folder disappears
once the session ends. For runs you want to keep, set a real location
once with `options(dragonfarm.runs_dir = "path/to/dragonfarm_runs")` or
the `DRAGONFARM_RUNS_DIR` environment variable, or pass `runs_dir=` to
the function you're calling.

## Usage

``` r
dragon_runs_dir()
```

## Value

A path.

## Examples

``` r
dragon_runs_dir()
#> [1] "/tmp/RtmplASM3q/dragonfarm_runs"
withr::with_options(list(dragonfarm.runs_dir = "~/dragonfarm_runs"), dragon_runs_dir())
#> [1] "~/dragonfarm_runs"
```
