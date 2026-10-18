# Index a document set for retrieval

Embeds every chunk with a small encoder (by default
`BAAI/bge-small-en-v1.5`, about 130 MB, downloaded once) and stores the
vectors next to the chunks.
[`dragon_documents()`](https://dragonfarm.dev/reference/dragon_documents.md)
does this for you unless `index = FALSE`; call this after editing files,
or to switch encoders. Nothing is re-embedded when the chunks have not
changed.

## Usage

``` r
dragon_index(docs, model = "BAAI/bge-small-en-v1.5", force = FALSE)
```

## Arguments

- docs:

  A `dragon_documents` object or its directory.

- model:

  Hugging Face id of a sentence-embedding model.

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
