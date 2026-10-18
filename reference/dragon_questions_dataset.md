# Training data from reviewed questions

Builds the dataset the fine-tune trains on: for every kept question, the
`k` most relevant excerpts are retrieved from the documents (by the
question, not the chunk it was written from, so training matches what
happens at answer time) and placed in the prompt ahead of it; the answer
is the response. This is the setup that beat a plain fine-tune in the
prototypes: the model learns to use excerpts, and the documents stay the
source of truth and can change later without retraining.

## Usage

``` r
dragon_questions_dataset(qa, docs = NULL, k = 4, cite = TRUE, negatives = 0.15)
```

## Arguments

- qa:

  A `dragon_questions` data frame (only rows with `keep = TRUE` are
  used).

- docs:

  The document set; defaults to the one the questions came from.

- k:

  Excerpts per prompt.

- cite:

  Append the excerpt number of the chunk each pair was written from to
  its answer (`" [2]"`), the way
  [`dragon_ask()`](https://dragonfarm.dev/reference/dragon_ask.md)
  cites, so the tuned model keeps citing. Answers that already contain a
  `[n]` marker are left alone. The source chunk is always among the
  excerpts: when retrieval misses it, it takes the last slot.

- negatives:

  Share of extra rows, relative to the kept questions, in which a
  question is shown with excerpts from a different section of the
  documents and the response is "The documents do not cover this."
  Without them every training prompt has its answer in the excerpts, and
  fine-tuned models learn to answer everything. Tuned on R's manuals, a
  0.5B, 1.5B, and 3B declined 0, 1, and 5 of 15 questions the manuals do
  not cover; with 15 percent negatives all three declined 15 of 15, and
  answered 26, 28, and 30 of 32 answerable questions, against 24, 29,
  and 30 without. `0` turns them off.

## Value

A mapped `dragon_dataset` ready for
[`dragon_train()`](https://dragonfarm.dev/reference/dragon_train.md).
Its data has a `negative` column marking the "not covered" rows.

## Examples

``` r
if (interactive()) {
docs <- dragon_documents(dragon_example_documents(), name = "policies")
qa <- dragon_questions(docs)
ds <- dragon_questions_dataset(qa)
dragon_preview(ds, n = 1)
}
```
