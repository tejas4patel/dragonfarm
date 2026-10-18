# Standard answer metrics for document answers (Q8), in the spirit of RAGAS
# but with as much fixed code as possible:
#   faithfulness      share of the answer's sentences the excerpts support
#                     (a local model says yes or no per sentence; sentences
#                     saying the documents do not cover it are left out)
#   context precision whether each excerpt helps answer the question (yes or
#                     no per excerpt), averaged with rank weights
#   context recall    whether any excerpt contains the known answer (a
#                     pattern; no model)
# A model never grades its own answer here: the judge is whatever backend
# and model the caller passes, and the verdicts are plain yes or no.

answer_sentences <- function(answer) {
  a <- gsub("\\s*\\[[0-9, ]+\\]", "", answer)
  a <- gsub("[[:space:]]+", " ", a)
  s <- trimws(unlist(strsplit(a, "(?<=[.!?])\\s+(?=[A-Z0-9\"(])", perl = TRUE)))
  s <- s[nchar(s) >= 12]
  s[!grepl(decline_pattern, s, ignore.case = TRUE, perl = TRUE)]
}

yes_no <- function(x) {
  x <- tolower(trimws(x))
  ifelse(grepl("^yes\\b", x), TRUE, ifelse(grepl("^no\\b", x), FALSE, NA))
}

excerpts_text <- function(hits) paste(sprintf("[%d] %s", hits$n, hits$text), collapse = "\n\n")

judge_yes_no <- function(prompts, backend, target) {
  if (!length(prompts)) return(logical())
  out <- backend_generate(backend, target, unname(lapply(prompts, function(p) list(list(role = "user", content = p)))),
                          max_new_tokens = 4, temperature = 0, top_p = 1)
  yes_no(unlist(out))
}

rag_faithfulness <- function(answer, hits, backend, target) {
  s <- answer_sentences(answer)
  if (!length(s)) return(list(score = NA_real_, sentences = 0L, supported = 0L))
  ctx <- excerpts_text(hits)
  v <- judge_yes_no(vapply(s, function(x) paste0(
    "Excerpts:\n\n", ctx, "\n\nStatement: ", x, "\n\n",
    "Is the statement supported by the excerpts above? Answer yes or no."), ""), backend, target)
  list(score = mean(v, na.rm = TRUE), sentences = length(s), supported = sum(v, na.rm = TRUE), unsupported = s[v %in% FALSE])
}

rag_context_precision <- function(question, hits, backend, target) {
  if (!nrow(hits)) return(NA_real_)
  v <- judge_yes_no(vapply(seq_len(nrow(hits)), function(i) paste0(
    "Question: ", question, "\n\nExcerpt: ", hits$text[i], "\n\n",
    "Does this excerpt contain information that helps answer the question? Answer yes or no."), ""), backend, target)
  v[is.na(v)] <- FALSE
  if (!any(v)) return(0)
  # average precision over the relevant positions, as RAGAS does
  mean(vapply(which(v), function(k) mean(v[seq_len(k)]), 0))
}

rag_context_recall <- function(hits, answer_pattern) {
  if (!nrow(hits) || is.null(answer_pattern) || is.na(answer_pattern)) return(NA)
  any(grepl(answer_pattern, hits$text, ignore.case = TRUE, perl = TRUE))
}

# All three for one dragon_ask() answer.
rag_metrics <- function(answer, judge_model = "Qwen/Qwen2.5-7B-Instruct", backend = dragon_backend(), answer_pattern = NULL) {
  target <- if (is_server_backend(backend)) NULL else resolve_target(judge_model)
  f <- rag_faithfulness(answer$answer, answer$sources, backend, target)
  list(faithfulness = f$score, sentences = f$sentences, unsupported = f$unsupported,
       context_precision = rag_context_precision(answer$question, answer$sources, backend, target),
       context_recall = rag_context_recall(answer$sources, answer_pattern))
}
