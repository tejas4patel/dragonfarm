# Generate replies from a fine-tuned model

Runs through the session's inference backend: by default a local Python
worker that keeps the last models loaded, so only the first call pays
the load. Pass a server backend to generate from Ollama or any
OpenAI-compatible endpoint instead. See
[dragon_backend](https://dragonfarm.dev/reference/dragon_backend.md).

## Usage

``` r
dragon_generate(
  x,
  prompt,
  system = NULL,
  max_new_tokens = 256,
  temperature = 0.7,
  top_p = 0.9,
  base = FALSE,
  backend = dragon_backend()
)
```

## Arguments

- x:

  A `dragon_run`, a run directory, an adapter directory, a merged model
  directory, or a Hugging Face model id.

- prompt:

  One or more user prompts.

- system:

  Optional system prompt.

- max_new_tokens:

  Maximum tokens to generate per reply.

- temperature:

  Sampling temperature. `0` means greedy decoding.

- top_p:

  Nucleus sampling threshold.

- base:

  Ignore this run's adapter and generate from what it started with: the
  base model, or the earlier run it continued from. Useful for
  before-and-after comparisons.

- backend:

  Where to run inference. See
  [dragon_backend](https://dragonfarm.dev/reference/dragon_backend.md).
  Server backends serve a fixed model and ignore `x`.

## Value

A character vector, one reply per prompt.

## Examples

``` r
if (interactive()) {
dragon_generate("HuggingFaceTB/SmolLM2-135M-Instruct", "Say hello in five words.")
}
```
