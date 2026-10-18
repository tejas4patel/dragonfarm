# Serve a run's model with Ollama

Merges the adapter into the base model (if not done already), registers
the result with Ollama, and checks that Ollama can answer with it. The
returned backend points
[`dragon_generate()`](https://dragonfarm.dev/reference/dragon_generate.md)
and [`dragon_chat()`](https://dragonfarm.dev/reference/dragon_chat.md)
at it.

## Usage

``` r
dragon_serve_ollama(run, name = NULL, quantize = NULL, ollama = ollama_path())
```

## Arguments

- run:

  A `dragon_run`, or a merged model directory.

- name:

  Model name to register. Defaults to `dragonfarm-<run id>`.

- quantize:

  Optional Ollama quantization such as `"q8_0"` or `"q4_K_M"` to shrink
  the served model.

- ollama:

  Path to the `ollama` executable.

## Value

A `dragon_backend` for the served model.

## Details

Recent Ollama versions import safetensors through their MLX engine. With
Ollama 0.40.5 on Windows the import worked but the model could not
answer ("MLX runtime is not available"), for Qwen and SmolLM2 runs
alike; other systems were not tested. When that happens the unusable
copy is removed and the error says so. A GGUF file made with
[`dragon_export_gguf()`](https://dragonfarm.dev/reference/dragon_export_gguf.md)
(which needs llama.cpp) is the other route into Ollama.

Needs Ollama installed and its service running. The `ollama` command is
looked for on the PATH and then in Ollama's usual install folders.

## Examples

``` r
if (interactive()) {
backend <- dragon_serve_ollama(run)
options(dragonfarm.backend = backend)
dragon_chat(run)$say("Hello")
}
```
