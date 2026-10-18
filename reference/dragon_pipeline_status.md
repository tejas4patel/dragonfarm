# Progress of a pipeline

Progress of a pipeline

## Usage

``` r
dragon_pipeline_status(x, runs_dir = dragon_runs_dir())
```

## Arguments

- x:

  A `dragon_pipeline` object or a pipeline id.

- runs_dir:

  Where the pipeline record lives, when `x` is an id.

## Value

The pipeline record as a list: `status`, `steps` (each with a state and,
when finished, a summary), and timestamps.

## Examples

``` r
if (interactive()) {
p <- dragon_pipeline("HuggingFaceTB/SmolLM2-135M-Instruct",
  list(dragon_step_train(dragon_map(dragon_dataset(dragon_example_data()),
                                  prompt = "{subject}\n\n{body}", response = "reply"))),
  background = TRUE)
dragon_pipeline_status(p)
}
```
