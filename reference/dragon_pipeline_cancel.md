# Cancel a pipeline

Writes a cancel request next to the pipeline record. The runner checks
it between steps and stops there. A training step that is under way is
asked to stop as well, the way
[`dragon_cancel()`](https://dragonfarm.dev/reference/dragon_cancel.md)
does, so it saves a checkpoint first; a judging, synthesis, or merge
step finishes before the pipeline stops. With `wait = TRUE` the call
returns once the pipeline has stopped, killing the pipeline process if
it is still going after `timeout` seconds.

## Usage

``` r
dragon_pipeline_cancel(
  x,
  runs_dir = dragon_runs_dir(),
  wait = TRUE,
  timeout = 120
)
```

## Arguments

- x:

  A `dragon_pipeline` handle or a pipeline id.

- runs_dir:

  Where the pipeline record lives, when `x` is an id.

- wait:

  Wait for the pipeline to stop.

- timeout:

  Seconds to wait before killing the pipeline process.

## Value

The pipeline status, invisibly.

## Examples

``` r
if (interactive()) {
p <- dragon_pipeline("HuggingFaceTB/SmolLM2-135M-Instruct",
  list(dragon_step_train(dragon_map(dragon_dataset(dragon_example_data()),
                                  prompt = "{subject}\n\n{body}", response = "reply"))),
  background = TRUE)
dragon_pipeline_cancel(p)
}
```
