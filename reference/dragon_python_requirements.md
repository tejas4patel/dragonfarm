# Python requirements used by dragonfarm

The package declares these with
[`reticulate::py_require()`](https://rstudio.github.io/reticulate/reference/py_require.html)
when it is loaded. You normally never call this yourself.

## Usage

``` r
dragon_python_requirements()
```

## Value

A list with `packages` (pip requirement strings) and `python_version`.

## Examples

``` r
dragon_python_requirements()
#> $packages
#>  [1] "torch>=2.4"                                     
#>  [2] "transformers>=4.46"                             
#>  [3] "peft>=0.13"                                     
#>  [4] "accelerate>=1.0"                                
#>  [5] "safetensors>=0.4"                               
#>  [6] "numpy"                                          
#>  [7] "sentencepiece"                                  
#>  [8] "protobuf"                                       
#>  [9] "huggingface_hub>=0.25"                          
#> [10] "pypdf>=4"                                       
#> [11] "cryptography>=3.1"                              
#> [12] "python-docx>=1.1"                               
#> [13] "openpyxl>=3.1"                                  
#> [14] "bitsandbytes>=0.45; platform_system != 'Darwin'"
#> [15] "unsloth>=2026.10.7; platform_system != 'Darwin'"
#> 
#> $python_version
#> [1] ">=3.10,<3.14"
#> 
```
