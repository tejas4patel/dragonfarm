# Inspect a run

`dragon_status()` reads the run's state. `dragon_progress()` returns one
row per logged step. `dragon_logs()` returns the tail of the trainer
log.

## Usage

``` r
dragon_status(run)

dragon_progress(run)

dragon_logs(run, n = 50)
```

## Arguments

- run:

  A `dragon_run`.

- n:

  Number of log lines to return.

## Value

`dragon_status()`: a list with at least `state`, one of `"queued"`,
`"running"`, `"succeeded"`, `"failed"`, `"cancelled"`.

`dragon_progress()`: a data frame with columns `step`, `epoch`, `loss`,
`eval_loss`, `lr`, `grad_norm`, `elapsed_s`, `eta_s`, and for preference
runs `pref_acc`, `reward_margin`, `eval_pref_acc`, `eval_reward_margin`.

`dragon_logs()`: a character vector.

## Examples

``` r
if (interactive()) {
run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))
dragon_status(run)$state
}
```
