# The chunks of a document set

The chunks of a document set

## Usage

``` r
dragon_chunks(docs)
```

## Arguments

- docs:

  A `dragon_documents` object or its directory.

## Value

A data frame with one row per chunk: `id`, `source`, `section`, `text`,
`n_words`, `quoted` (a block quote), `code` (a code block), and `weight`
(0.7 for changelog-like sources, else 1).

## Examples

``` r
if (interactive()) {
docs <- dragon_documents(dragon_example_documents(), name = "policies")
head(dragon_chunks(docs))
}
```
