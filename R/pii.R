# Personal data in documents, found by fixed patterns (no model), so the
# result is the same every time and can be shown to an auditor. It looks for
# what most often slips into business documents: email addresses, phone
# numbers, US social security numbers, payment card numbers (with the Luhn
# check), dates of birth (only when labelled as such), and patient or record
# ids (only when labelled). Organisation contact lines are common in public
# documents (an agency's phone number), so every hit is listed with its
# context for a person to judge. Redaction replaces hits with [TYPE].

pii_patterns <- list(
  email = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
  phone = "(?<![\\d.])(?:\\+?1[ .-]?)?(?:\\(\\d{3}\\)[ .-]?|\\d{3}[ .-])\\d{3}[ .-]\\d{4}(?![\\d.])",
  ssn = "(?<!\\d)(?!000|666|9\\d\\d)\\d{3}-(?!00)\\d{2}-(?!0000)\\d{4}(?!\\d)",
  card = "(?<!\\d)(?:\\d[ -]?){12,15}\\d(?!\\d)",
  birth_date = "(?i)\\b(?:date of birth|DOB|born(?: on)?)\\s*[:.]?\\s*(?:\\d{1,2}[/-]\\d{1,2}[/-]\\d{2,4}|\\d{4}-\\d{2}-\\d{2}|[A-Z][a-z]+ \\d{1,2},? \\d{4})",
  record_id = "(?i)\\b(?:MRN|medical record (?:number|no\\.?)|patient (?:id|number|no\\.?)|subject id)\\s*[:#]?\\s*[A-Z0-9-]{4,}"
)

luhn_ok <- function(x) {
  d <- as.integer(rev(strsplit(gsub("[^0-9]", "", x), "")[[1]]))
  if (length(d) < 13 || length(d) > 16) return(FALSE)
  even <- seq_along(d) %% 2 == 0
  d[even] <- d[even] * 2
  d[d > 9] <- d[d > 9] - 9
  sum(d) %% 10 == 0
}

# Every hit in one text: type, the matched text, and some context.
pii_find <- function(text) {
  out <- list()
  for (type in names(pii_patterns)) {
    m <- gregexpr(pii_patterns[[type]], text, perl = TRUE)[[1]]
    if (m[1] == -1) next
    hits <- regmatches(text, list(m))[[1]]
    keep <- if (identical(type, "card")) vapply(hits, luhn_ok, TRUE) else rep(TRUE, length(hits))
    for (i in which(keep)) {
      s <- max(1, m[i] - 40); e <- min(nchar(text), m[i] + attr(m, "match.length")[i] + 40)
      out[[length(out) + 1]] <- data.frame(type = type, match = hits[i], context = gsub("[[:space:]]+", " ", substr(text, s, e)))
    }
  }
  if (!length(out)) return(data.frame(type = character(), match = character(), context = character()))
  do.call(rbind, out)
}

pii_redact <- function(text) {
  for (type in names(pii_patterns)) {
    if (identical(type, "card")) {
      m <- gregexpr(pii_patterns$card, text, perl = TRUE)[[1]]
      if (m[1] == -1) next
      hits <- regmatches(text, list(m))[[1]]
      for (h in hits[vapply(hits, luhn_ok, TRUE)]) text <- sub(h, "[CARD]", text, fixed = TRUE)
    } else {
      text <- gsub(pii_patterns[[type]], sprintf("[%s]", toupper(type)), text, perl = TRUE)
    }
  }
  text
}

# Scan a document set's chunks. Returns the hits with their chunk and source,
# and records a summary (counts by type, never the values) in the catalogue.
pii_scan <- function(docs, runs_dir = dragon_runs_dir()) {
  docs <- as_documents(docs)
  ch <- dragon_chunks(docs)
  hits <- lapply(seq_len(nrow(ch)), function(i) {
    h <- pii_find(ch$text[i])
    if (nrow(h)) cbind(chunk = ch$id[i], source = ch$source[i], h) else NULL
  })
  hits <- do.call(rbind, Filter(Negate(is.null), hits))
  if (is.null(hits)) hits <- data.frame(chunk = character(), source = character(), type = character(), match = character(), context = character())
  counts <- as.list(table(factor(hits$type, levels = names(pii_patterns))))
  store_record_event("pii_scan", docs$name, ok = nrow(hits) == 0, detail = list(chunks = nrow(ch), found = counts), runs_dir = runs_dir)
  structure(hits, counts = unlist(counts), class = c("dragon_pii", "data.frame"))
}

# Personal data in a training set (D-11): every text cell, conversations
# included, by the same fixed patterns. One row per hit with the data row it
# is in. Large sets are scanned up to max_rows rows.
dataset_pii <- function(dataset, max_rows = 20000L) {
  d <- if (is.list(dataset)) dataset$data
  if (!is.data.frame(d) || !nrow(d)) return(data.frame(row = integer(), type = character(), match = character(), context = character()))
  d <- utils::head(d, max_rows)
  cell_text <- function(v) {
    if (is.character(v)) return(v)
    if (is.list(v)) return(vapply(v, function(x) paste(unlist(lapply(x, function(m) if (is.list(m)) m$content else m)), collapse = "\n"), ""))
    NULL
  }
  out <- list()
  for (col in names(d)) {
    txt <- cell_text(d[[col]])
    if (is.null(txt)) next
    for (i in which(!is.na(txt) & nzchar(txt))) {
      h <- pii_find(txt[i])
      if (nrow(h)) out[[length(out) + 1]] <- cbind(row = i, h)
    }
  }
  if (!length(out)) return(data.frame(row = integer(), type = character(), match = character(), context = character()))
  out <- do.call(rbind, out)
  out[!duplicated(out[c("row", "type", "match")]), , drop = FALSE]   # a text shown in two columns counts once
}

pii_counts <- function(hits) {
  if (!nrow(hits)) return("")
  tab <- table(hits$type)
  paste(sprintf("%d %s", as.integer(tab), names(tab)), collapse = ", ")
}
