# Evaluate a finished run

Training already evaluates on the held-out rows and writes the result
into the run directory. This function reads that result, or recomputes
it with the saved adapter when `recompute = TRUE` or nothing was saved.

## Usage

``` r
dragon_evaluate(run, n_samples = 10, recompute = FALSE, metrics = NULL)
```

## Arguments

- run:

  A `dragon_run` or run directory.

- n_samples:

  Number of held-out prompts to generate replies for. `Inf` generates
  for every held-out row.

- recompute:

  Reload the model and evaluate again.

- metrics:

  Task metrics to compute on the generated replies: `TRUE` for every
  built-in metric, a character vector of names from
  [`dragon_metrics()`](https://dragonfarm.dev/reference/dragon_metrics.md),
  or a named list of functions. Metrics need a reply for every held-out
  row, so replies are generated for all of them when fewer are on disk.
  Results are saved to `metrics.json` in the run and show up in
  [`dragon_compare()`](https://dragonfarm.dev/reference/dragon_compare.md).

## Value

A list with `eval_loss`, `perplexity`, `eval_tokens`, and a `samples`
data frame with columns `prompt`, `reference`, `generated`. Preference
runs report `pref_accuracy` (how often the model scores the chosen reply
above the rejected one), `reward_margin`, and `eval_pairs` instead of
perplexity, and their samples also carry `rejected`.

## Examples

``` r
if (interactive()) {
run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))
dragon_evaluate(run, n_samples = 5)
}
```
