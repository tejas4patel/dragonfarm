# Load, save, and list question sets

Load, save, and list question sets

## Usage

``` r
dragon_questions_load(path)

dragon_questions_save(qa, path = attr(qa, "path"))

dragon_questions_list(docs)
```

## Arguments

- path:

  A questions file (`<set>/questions/<stamp>.jsonl`), or a
  `dragon_questions` object for `dragon_questions_save()`.

- qa:

  A `dragon_questions` data frame whose `keep` column you edited.

- docs:

  A `dragon_documents` object or directory.

## Value

`dragon_questions_load()` and `dragon_questions_save()` return the
`dragon_questions` data frame; `dragon_questions_list()` a data frame of
the set's question files with counts.

## Examples

``` r
if (interactive()) {
docs <- dragon_documents(dragon_example_documents(), name = "policies")
qa <- dragon_questions(docs)
qa <- dragon_questions_load(attr(qa, "path"))
}
```
