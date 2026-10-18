# Cancel a run

Asks the trainer to stop after the current step and save a checkpoint.
Falls back to killing the process if it does not stop in time.

## Usage

``` r
dragon_cancel(run, timeout = 120)
```

## Arguments

- run:

  A `dragon_run`.

- timeout:

  Seconds to wait for a clean stop.

## Value

The run, invisibly.

## Examples

``` r
if (interactive()) {
run <- dragon_dataset(dragon_example_data()) |>
  dragon_map(prompt = "{subject}\n\n{body}", response = "reply") |>
  dragon_train("HuggingFaceTB/SmolLM2-135M-Instruct")
dragon_cancel(run)
}
```
