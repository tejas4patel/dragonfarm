# Export a merged model to GGUF

Converts a merged model directory to GGUF for use with llama.cpp,
Ollama, and similar runtimes. Requires a llama.cpp checkout; point the
`LLAMA_CPP_DIR` environment variable at it.

## Usage

``` r
dragon_export_gguf(
  merged_dir,
  out_file = NULL,
  quant = "q8_0",
  llama_cpp_dir = Sys.getenv("LLAMA_CPP_DIR", unset = "")
)
```

## Arguments

- merged_dir:

  A merged model directory from
  [`dragon_merge()`](https://dragonfarm.dev/reference/dragon_merge.md).

- out_file:

  Output path. Defaults to `model-<quant>.gguf` next to the model.

- quant:

  Output type passed to the converter, such as `"q8_0"`, `"f16"`, or
  `"bf16"`.

- llama_cpp_dir:

  Path to a llama.cpp checkout containing `convert_hf_to_gguf.py`.

## Value

The output path, invisibly.

## Examples

``` r
if (interactive()) {
run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))
dragon_export_gguf(dragon_merge(run))
}
```
