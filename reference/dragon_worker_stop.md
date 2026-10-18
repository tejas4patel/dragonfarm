# Stop the local inference worker

The local backend keeps a Python process alive with the last models
loaded. Call this to free the memory (GPU included). It restarts on the
next generation call.

## Usage

``` r
dragon_worker_stop(all = FALSE)
```

## Arguments

- all:

  Also stop dragonfarm processes started by other R sessions.

## Value

`TRUE` invisibly.

## Details

A worker started by another R session (an app left open in a second
console, a session that ended without stopping it) keeps its GPU memory
and is invisible to this one. `dragon_worker_stop(all = TRUE)` finds
every dragonfarm Python process on the machine and stops it: inference
workers, question generators, and trainers alike, so check
[`dragon_runs()`](https://dragonfarm.dev/reference/dragon_runs.md) first
if a run might be in progress.
[`dragon_check()`](https://dragonfarm.dev/reference/dragon_check.md)
lists them without stopping anything.

## Examples

``` r
if (interactive()) {
dragon_worker_stop()
}
```
