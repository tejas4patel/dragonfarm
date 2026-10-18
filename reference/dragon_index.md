# Index a document set for retrieval

Embeds every chunk with a small encoder and stores the vectors next to
the chunks. By default the encoder is `BAAI/bge-small-en-v1.5` (about
130 MB, downloaded once); a set whose text is mostly not English is
indexed with `intfloat/multilingual-e5-small` instead. On German
medicine product information (8 documents, 58 questions) it put the
passage a question came from in the top four results for 55 percent of
questions, against 45 percent for the English model.
[`dragon_documents()`](https://dragonfarm.dev/reference/dragon_documents.md)
does this for you unless `index = FALSE`; call this after editing files,
or to switch encoders. Nothing is re-embedded when the chunks have not
changed.

## Usage

``` r
dragon_index(docs, model = NULL, force = FALSE)
```

## Arguments

- docs:

  A `dragon_documents` object or its directory.

- model:

  Hugging Face id of a sentence-embedding model, or `NULL` to choose by
  the set's language as described above.

- force:

  Re-embed even if the index already matches the chunks.

## Value

The `dragon_documents` object, reloaded, invisibly.

## Examples

``` r
if (interactive()) {
docs <- dragon_documents(dragon_example_documents(), name = "policies", index = FALSE)
docs <- dragon_index(docs)
}
```
