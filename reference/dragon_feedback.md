# Training data from chat feedback

Ratings and edits made in
[`dragon_chat()`](https://dragonfarm.dev/reference/dragon_chat.md) or
the app's Chat panel are saved under `feedback/` in the runs directory.
This turns them into data for the next stage:

## Usage

``` r
dragon_feedback(runs_dir = dragon_runs_dir(), label = NULL)
```

## Arguments

- runs_dir:

  Runs directory holding `feedback/feedback.jsonl`.

- label:

  Optional filter: only feedback given to this run id or backend model.

## Value

A list with `records` (a data frame of every feedback event), `sft`
(dataset or `NULL`), and `pairs` (dataset or `NULL`).

## Details

- `sft`: a conversations dataset
  ([`dragon_conversations()`](https://dragonfarm.dev/reference/dragon_conversations.md))
  of replies the user liked or edited, each with the turns that led to
  it. Edited text replaces the model's reply.

- `pairs`: a preference dataset
  ([`dragon_map_pairs()`](https://dragonfarm.dev/reference/dragon_map_pairs.md))
  for prompts that received both a liked (or edited) reply and a
  disliked one.

Both are written as JSONL under `feedback/` so runs trained on them stay
reproducible through
[`dragon_code()`](https://dragonfarm.dev/reference/dragon_code.md).

## Examples

``` r
if (interactive()) {
run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))   # the run people chatted with
fb <- dragon_feedback()
fb$records
if (!is.null(fb$sft)) better <- dragon_train(fb$sft, run, wait = TRUE)
if (!is.null(fb$pairs)) dpo2 <- dragon_prefer(fb$pairs, better, wait = TRUE)
}
```
