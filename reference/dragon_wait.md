# Wait for a run to finish

Blocks with a progress bar until the run reaches a terminal state.

## Usage

``` r
dragon_wait(run, timeout = Inf, poll = 2)
```

## Arguments

- run:

  A `dragon_run`.

- timeout:

  Seconds to wait before giving up (the run keeps going).

- poll:

  Seconds between checks.

## Value

The run, invisibly. Errors if the run failed.

## Examples

``` r
if (interactive()) {
run <- dragon_dataset(dragon_example_data()) |>
  dragon_map(prompt = "{subject}\n\n{body}", response = "reply") |>
  dragon_train("HuggingFaceTB/SmolLM2-135M-Instruct")
dragon_wait(run)
}
```
