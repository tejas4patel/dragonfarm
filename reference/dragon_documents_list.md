# List saved document sets

List saved document sets

## Usage

``` r
dragon_documents_list(runs_dir = dragon_runs_dir())
```

## Arguments

- runs_dir:

  Parent directory, as for
  [`dragon_documents()`](https://dragonfarm.dev/reference/dragon_documents.md).

## Value

A data frame with one row per set: `name`, `sources`, `chunks`,
`indexed`, `updated_at`, `dir`.

## Examples

``` r
dragon_documents_list(tempdir())
#> [1] name       sources    chunks     indexed    updated_at dir       
#> <0 rows> (or 0-length row.names)
```
