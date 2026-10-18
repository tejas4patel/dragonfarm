# Hold out rows for evaluation

If you do not call this,
[`dragon_train()`](https://dragonfarm.dev/reference/dragon_train.md)
holds out 5 percent of rows (and none when the dataset has fewer than 20
rows).

## Usage

``` r
dragon_split(dataset, eval_frac = 0.05, seed = 42)
```

## Arguments

- dataset:

  A `dragon_dataset`.

- eval_frac:

  Fraction of rows to hold out.

- seed:

  Random seed for the split.

## Value

The dataset with the split attached.

## Examples

``` r
ds <- dragon_map(dragon_dataset(dragon_example_data()),
                 prompt = "{subject}\n\n{body}", response = "reply")
ds <- dragon_split(ds, eval_frac = 0.1)
ds$split
#> $eval_frac
#> [1] 0.1
#> 
#> $seed
#> [1] 42
#> 
#> $eval_idx
#>  [1]  20  24  47  49  65  71  74  89 100 110 111 114 122 128 131 146 153 154 165
#> [20] 200
#> 
```
