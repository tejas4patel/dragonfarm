# Serve a run's model with Ollama

Merges the adapter into the base model (if not done already), registers
the result with Ollama, and checks that Ollama can answer with it. The
returned backend points
[`dragon_generate()`](https://dragonfarm.dev/reference/dragon_generate.md)
and [`dragon_chat()`](https://dragonfarm.dev/reference/dragon_chat.md)
at it.

## Usage

``` r
dragon_serve_ollama(
  run,
  name = NULL,
  quantize = NULL,
  ollama = ollama_path(),
  llama_cpp_dir = Sys.getenv("LLAMA_CPP_DIR", unset = "")
)
```

## Arguments

- run:

  A `dragon_run`, or a merged model directory.

- name:

  Model name to register. Defaults to `dragonfarm-<run id>`.

- quantize:

  Optional quantization such as `"q8_0"` to shrink the served model. On
  the GGUF route it is the converter's output type (default `"q8_0"`).

- ollama:

  Path to the `ollama` executable.

- llama_cpp_dir:

  A llama.cpp checkout; when it holds the converter, the GGUF route is
  used.

## Value

A `dragon_backend` for the served model.

## Details

With a llama.cpp checkout (`LLAMA_CPP_DIR`), the merged model is first
converted to GGUF with
[`dragon_export_gguf()`](https://dragonfarm.dev/reference/dragon_export_gguf.md)
and Ollama serves that file; this worked with Ollama 0.40.5 on Windows.
Without one, Ollama is asked to import the safetensors directly. Recent
Ollama versions do that through their MLX engine, which on Windows
refused a Qwen run and could not run a SmolLM2 one ("MLX runtime is not
available"); the unusable copy is then removed and the error says so.

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
