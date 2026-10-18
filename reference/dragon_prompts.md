# Prompts from a run's data files

The user turns of a run's training or held-out rows, for feeding
[`dragon_synthesize_pairs()`](https://dragonfarm.dev/reference/dragon_synthesize_pairs.md)
or [`dragon_judge()`](https://dragonfarm.dev/reference/dragon_judge.md).
Works for prompt/response and preference-pair runs alike.

## Usage

``` r
dragon_prompts(run, split = c("eval", "train"), n = Inf, seed = 42)
```

## Arguments

- run:

  A `dragon_run` or run directory.

- split:

  `"eval"` for the held-out rows, `"train"` for the rest.

- n:

  Maximum number of prompts. `Inf` for all.

- seed:

  Seed used when sampling down to `n`.

## Value

A character vector.

## Examples

``` r
if (interactive()) {
run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))
head(dragon_prompts(run, split = "eval", n = 5))
}
```
