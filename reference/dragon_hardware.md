# Hardware settings

Hardware settings

## Usage

``` r
dragon_hardware(
  device = c("auto", "cuda", "mps", "cpu"),
  dtype = c("auto", "bfloat16", "float16", "float32"),
  load_in_4bit = FALSE
)
```

## Arguments

- device:

  `"auto"` picks CUDA, then Apple MPS, then CPU. Or name one.

- dtype:

  `"auto"` picks bfloat16 on GPUs that support it, float16 on older
  GPUs, and float32 elsewhere.

- load_in_4bit:

  Load the base model in 4-bit through bitsandbytes (QLoRA when
  training). Needs an NVIDIA GPU; works on Linux and Windows. For
  generation, prefer the `load_in_4bit` argument of
  [`dragon_backend_local()`](https://dragonfarm.dev/reference/dragon_backend.md),
  which decides per model.

## Value

A `dragon_hardware` object.

## Examples

``` r
dragon_hardware()
#> $device
#> [1] "auto"
#> 
#> $dtype
#> [1] "auto"
#> 
#> $load_in_4bit
#> [1] FALSE
#> 
#> attr(,"class")
#> [1] "dragon_hardware"
dragon_hardware(device = "cpu")
#> $device
#> [1] "cpu"
#> 
#> $dtype
#> [1] "auto"
#> 
#> $load_in_4bit
#> [1] FALSE
#> 
#> attr(,"class")
#> [1] "dragon_hardware"
```
