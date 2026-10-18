# Inference backends

Every function that generates text,
[`dragon_generate()`](https://dragonfarm.dev/reference/dragon_generate.md),
[`dragon_chat()`](https://dragonfarm.dev/reference/dragon_chat.md), the
judge, teacher, and synthesis helpers, takes a `backend`. The default is
the local worker; set `options(dragonfarm.backend = ...)` to change it
for a session.

## Usage

``` r
dragon_backend_local(
  keep_loaded = TRUE,
  device = "auto",
  dtype = "auto",
  load_in_4bit = "auto"
)

dragon_backend_server(
  url,
  model,
  api_key = NULL,
  headers = NULL,
  api_key_env = NULL
)

dragon_backend_ollama(model, url = "http://localhost:11434")

dragon_backend()
```

## Arguments

- keep_loaded:

  Keep the worker and its models alive between calls.

- device, dtype:

  Device and precision for the local worker. See
  [`dragon_hardware()`](https://dragonfarm.dev/reference/dragon_hardware.md).

- load_in_4bit:

  Load models in 4-bit (NF4 through bitsandbytes) on an NVIDIA GPU.
  `"auto"`, the default, quantizes only models whose full weights would
  not fit: a 7B on an 8 GB card, not a 3B. `TRUE` forces it, `FALSE`
  never does. A 4-bit 7B uses about the memory of a 3B in full precision
  and generates about 40 percent slower per token. The weights are
  downloaded in full (about 15 GB for a 7B) and quantized at load.

- url:

  Base URL of the server, ending in `/v1`.

- model:

  Model name as the server knows it.

- api_key:

  Bearer token, if the server needs one. Prefer `api_key_env`: a key
  given here is kept inside the backend object, so it travels wherever
  the object is saved (a background job, for example), and a warning
  says so once per session.

- headers:

  Extra HTTP headers as a named character vector.

- api_key_env:

  Name of the environment variable that holds the key, read each time a
  request is sent, so the key is never stored. Defaults to
  `DRAGONFARM_API_KEY` when it is set, else `OPENAI_API_KEY`.

## Value

A `dragon_backend` object.

## Details

- `dragon_backend_local()`: a Python worker on this machine that keeps
  the last two models loaded, so repeated calls pay the model load once.
  `keep_loaded = FALSE` stops it after every call.

- `dragon_backend_server()`: any server that speaks the OpenAI chat
  completions protocol. `url` is the base that ends in `/v1`. The model
  must already be available on that server; see
  [`dragon_serve_ollama()`](https://dragonfarm.dev/reference/dragon_serve_ollama.md)
  for the local case.

- `dragon_backend_ollama()`: a server backend for a model registered
  with Ollama on this machine.

- `dragon_backend()`: the session default.

## Examples

``` r
if (interactive()) {
options(dragonfarm.backend = dragon_backend_ollama("support-0.5b"))
dragon_generate(run, "My thermostat keeps dropping off Wi-Fi.")

vllm <- dragon_backend_server("https://my-pod.example.com/v1", model = "tejas/support-0.5b")
dragon_generate(run, "Hello", backend = vllm)
}
```
