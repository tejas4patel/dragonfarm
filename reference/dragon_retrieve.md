# Find the chunks most relevant to a question

Find the chunks most relevant to a question

## Usage

``` r
dragon_retrieve(docs, query, k = 4, method = c("hybrid", "dense"), extra = 0)
```

## Arguments

- docs:

  A `dragon_documents` object or its directory. Indexed on the fly if it
  has no index yet.

- query:

  One question, or several.

- k:

  Chunks to return per query.

- method:

  `"hybrid"` (the default) ranks chunks by combining the embedding
  similarity with a keyword (`BM25`) match, which catches exact terms
  and figures a small embedding model ranks too low; `"dense"` uses the
  embedding alone. On three document sets hybrid raised the share of
  questions whose source chunk was among the top four from 90.6 to 93.0,
  88 to 100, and 91 to 100 percent.

- extra:

  Chunks to add after the top `k` that say something different from
  those already chosen (relevant, but not near-copies). A rule that
  several documents repeat and one later document words differently is
  otherwise crowded out; the top `k` itself is unchanged.

## Value

A data frame with one row per hit: `query` (when several), `n` (rank),
`id`, `source`, `section`, `page` (PDFs), `text`, `score` (cosine
similarity times the chunk's weight; rows are ordered by the combined
ranking, so it need not decrease), `similarity`, and `weight`.
