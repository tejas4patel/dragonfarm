# scripts/retrieval_eval_paraphrased.json, the harder retrieval test set
# (127 questions; run from the repository root with the sets read): paraphrased questions (everyday words, not the
# passage's own) written by the 7B from sampled passages, kept only if
#   - the quoted answer appears verbatim in the passage,
#   - the question shares few content words with the passage,
#   - the 7B answers it from that passage alone, and
#   - the 7B declines it given four unrelated passages from the same set.
suppressMessages(devtools::load_all(quiet = TRUE))
H <- "scripts"
options(dragonfarm.runs_dir = path.expand("~/dragonfarm_runs"))
model <- "Qwen/Qwen2.5-7B-Instruct"
target <- resolve_target(model)
be <- dragon_backend()
sets <- c("r-manuals", "fda-stats", "costco-2024", "r-heldout")
per_set <- 180
stop_words <- c("the", "a", "an", "of", "to", "in", "and", "or", "is", "are", "for", "on", "with", "by", "be", "as", "at", "it",
                "that", "this", "what", "which", "how", "does", "do", "can", "if", "from", "when", "why", "who", "was", "were",
                "its", "their", "there", "into", "about", "should", "would", "will", "than", "then", "has", "have", "not", "any",
                "you", "your", "i", "my", "we", "our", "they", "them", "these", "those", "such", "also", "may", "more", "most")
words <- function(x) { w <- unique(tolower(unlist(strsplit(x, "[^A-Za-z0-9]+")))); w[nchar(w) > 2 & !w %in% stop_words] }
overlap <- function(q, text) { qw <- words(q); if (!length(qw)) return(1); mean(qw %in% words(text)) }

gen_prompt <- function(text) paste0(
  "Here is a passage from a document:\n\n", text, "\n\n",
  "Write ONE question that this passage answers, as a person would ask it who has never read the passage. ",
  "Use your own everyday words: do not reuse the passage's distinctive terms, names of sections, or phrases; describe them instead. ",
  "The question must have one short, specific answer in the passage. ",
  "Then copy the shortest exact phrase from the passage (3 to 10 words, copied character for character) that contains the answer.\n\n",
  "Reply in exactly this format:\nQUESTION: <question>\nANSWER: <exact phrase from the passage>")

check_prompt <- function(q, texts) paste0(
  "Excerpts:\n\n", paste(sprintf("[%d] %s", seq_along(texts), texts), collapse = "\n\n"),
  "\n\nQuestion: ", q, "\n\nAnswer in one sentence using only the excerpts. If they do not contain the answer, reply exactly: NOT IN EXCERPTS")

gen <- function(prompts, max_new = 160) {
  out <- character()
  for (b in split(prompts, ceiling(seq_along(prompts) / 8))) {
    out <- c(out, unlist(backend_generate(be, target, lapply(b, function(p) list(list(role = "user", content = p))),
                                          max_new_tokens = max_new, temperature = 0, top_p = 1)))
  }
  out
}

set.seed(20261017)
rows <- list()
for (s in sets) {
  ch <- read_jsonl(file.path(getOption("dragonfarm.runs_dir"), "documents", s, "chunks.jsonl"))
  text <- vapply(ch, `[[`, "", "text")
  ok <- nchar(text) >= 400 & nchar(text) <= 3000
  pick <- sample(which(ok), min(per_set, sum(ok)))
  raw <- gen(vapply(pick, function(i) gen_prompt(text[i]), ""))
  q <- trimws(sub("(?s).*QUESTION:\\s*(.*?)\\s*ANSWER:.*", "\\1", raw, perl = TRUE))
  a <- trimws(gsub('^["\u201c]|["\u201d.]$', "", trimws(sub("(?s).*ANSWER:\\s*(.*)$", "\\1", raw, perl = TRUE))))
  a <- sub("\n.*$", "", a)
  verbatim <- mapply(function(ans, i) nchar(ans) >= 3 && grepl(ans, text[i], fixed = TRUE), a, pick)
  ov <- mapply(overlap, q, text[pick])
  cand <- which(verbatim & grepl("[?]$", q) & ov <= 0.5)
  cat(s, ": generated", length(pick), "| verbatim", sum(verbatim), "| low overlap", sum(verbatim & ov <= 0.5), "\n")
  if (!length(cand)) next
  own <- gen(vapply(cand, function(j) check_prompt(q[j], text[pick[j]]), ""), 80)
  others <- vapply(cand, function(j) { o <- sample(setdiff(seq_along(text), pick[j]), 4); check_prompt(q[j], text[o]) }, "")
  away <- gen(others, 80)
  keep <- !grepl("NOT IN EXCERPTS", own) & grepl("NOT IN EXCERPTS", away)
  cat(s, ": answered from own passage", sum(!grepl("NOT IN EXCERPTS", own)), "| declined elsewhere", sum(grepl("NOT IN EXCERPTS", away)),
      "| kept", sum(keep), "\n")
  for (j in cand[keep]) {
    rows[[length(rows) + 1]] <- list(set = s, question = q[j], answer_contains = a[j], overlap = round(ov[j], 2), kind = "paraphrase")
  }
}
jsonlite::write_json(rows, file.path(H, "retrieval_eval_paraphrased.json"), auto_unbox = TRUE, pretty = TRUE)
cat("total kept", length(rows), "\n")
dragon_worker_stop()
