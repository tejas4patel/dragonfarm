# Ask a question of your documents

Retrieves the `k` most relevant chunks, puts them in front of a language
model as numbered excerpts, and asks it to answer from them with
citations. No training is involved; swap documents and ask again. The
model can be anything
[`dragon_generate()`](https://dragonfarm.dev/reference/dragon_generate.md)
accepts: a base model id, a fine-tuned run, or whatever a server backend
serves.

## Usage

``` r
dragon_ask(
  docs,
  question,
  model = NULL,
  k = 4,
  system = NULL,
  backend = dragon_backend(),
  max_new_tokens = 600,
  temperature = 0,
  top_p = 0.9,
  base = FALSE,
  on_stage = NULL,
  on_token = NULL,
  compare = FALSE
)
```

## Arguments

- docs:

  A `dragon_documents` object or its directory.

- question:

  The question.

- model:

  What answers. Defaults to the model recommended for this machine's GPU
  memory (see
  [`dragon_check()`](https://dragonfarm.dev/reference/dragon_check.md)):
  a 1.5B under 6 GB, a 3B at 6 to 8 GB, a 7B in 4-bit at 8 GB and up.
  Ignored by server backends.

- k:

  Excerpts to retrieve.

- system:

  Extra instructions, added to the built-in ones about answering only
  from the excerpts and citing them.

- backend:

  Where to run inference. See
  [dragon_backend](https://dragonfarm.dev/reference/dragon_backend.md).

- max_new_tokens, temperature, top_p:

  Generation settings. Temperature 0 (the default) is deterministic,
  which suits factual answers.

- base:

  When `model` is a run, answer with what it started from instead (as in
  [`dragon_generate()`](https://dragonfarm.dev/reference/dragon_generate.md)),
  for before-and-after comparisons.

- on_stage:

  Optional function called with a short message before each stage
  (finding excerpts, loading the model, answering), for progress
  displays. The first question in a session loads the model, which can
  take a minute for a 7B.

- on_token:

  Optional function called with each piece of the answer as it is
  generated, for showing it as it is written (backends that stream: the
  local worker and servers). A reply that is asked again because it was
  only a citation is not streamed; the returned answer is final.

- compare:

  Look for documents that disagree: adds two excerpts that say something
  different from the top `k`, and asks the model to give each document's
  version when they differ. On a test set of rules that one later
  document changes, a 7B named both versions in 13 of 24 answers instead
  of 6; it still sometimes calls differing documents consistent, so
  check the sources.

## Value

A `dragon_answer`: `$answer`, `$sources` (a data frame of the excerpts
with `n`, `source`, `section`, `text`, `score`, and `cited`, whether the
answer refers to it), `$question`, and `$model`.
[`print()`](https://rdrr.io/r/base/print.html) shows the answer with its
footnotes.

## Examples

``` r
if (interactive()) {
docs <- dragon_documents("policies.pdf")
ans <- dragon_ask(docs, "How long is the return window?")
ans
ans$sources
}
```
