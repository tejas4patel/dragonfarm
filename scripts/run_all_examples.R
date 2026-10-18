# Run every help-page example for real, including the ones wrapped in
# if (interactive()) that R CMD check never runs. Each topic runs in its own
# R process with interactive() forced on, all sharing one fresh runs folder
# (so examples that open "the first run" find the one the training example
# made). Examples that use placeholder files, outside services or the app
# are skipped and listed. Uses the GPU (small models only).
#   Rscript scripts/run_all_examples.R [out dir] [topic,topic,...]
args <- commandArgs(trailingOnly = TRUE)
S <- if (length(args)) args[[1]] else tempfile("examples-")
dir.create(S, showWarnings = FALSE, recursive = TRUE)
runs <- file.path(S, "runs")
pkg <- normalizePath(".")
skip_if <- c("policies\\.pdf", "\"policies/\"", "example\\.com", "dragon_publish", "dragon_llm_anthropic", "kaggle", "lightning",
             "ellmer", "mcp", "ollama", "dragon_backend_server", "dragon_app\\(", "ANTHROPIC", "HF_TOKEN", "dragon_remote",
             "dragon_bundle", "dragon_import", "dragon_chat\\(", "my_tickets", "tickets\\.csv",
             "arithmetic\\.csv", "dragon_export_gguf")   # a placeholder file; a llama.cpp checkout
# Training first, so later examples find a run.
order_first <- c("dragon_train", "dragon_documents", "dragon_questions")
topics <- sub("[.]Rd$", "", list.files(file.path(pkg, "man"), pattern = "[.]Rd$"))
topics <- c(intersect(order_first, topics), setdiff(topics, order_first))
if (length(args) > 1) topics <- c("dragon_train", intersect(strsplit(args[[2]], ",")[[1]], topics))   # a run first, then these
rows <- list()
for (t in topics) {
  ex <- file.path(S, paste0(t, ".R"))
  tools::Rd2ex(file.path(pkg, "man", paste0(t, ".Rd")), ex, commentDontrun = FALSE)
  if (!file.exists(ex)) { rows[[t]] <- data.frame(topic = t, result = "no example", seconds = NA, note = ""); next }
  code <- readLines(ex, warn = FALSE)
  hit <- skip_if[vapply(skip_if, function(p) any(grepl(p, code, ignore.case = TRUE)), TRUE)]
  if (length(hit)) { rows[[t]] <- data.frame(topic = t, result = "skipped", seconds = NA, note = paste(hit, collapse = " ")); next }
  t0 <- Sys.time()
  res <- tryCatch(callr::r(function(ex, runs, pkg) {
    devtools::load_all(pkg, quiet = TRUE)
    options(dragonfarm.runs_dir = runs)
    env <- new.env(parent = globalenv())
    env$interactive <- function() TRUE
    sys.source(ex, envir = env)
    "ok"
  }, args = list(ex = ex, runs = runs, pkg = pkg), timeout = 1800, stdout = file.path(S, paste0(t, ".out")), stderr = "2>&1"),
  error = function(e) paste("FAILED:", gsub("[[:space:]]+", " ", substr(conditionMessage(e), 1, 300))))
  secs <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")))
  rows[[t]] <- data.frame(topic = t, result = if (identical(res, "ok")) "ok" else "failed", seconds = secs, note = if (identical(res, "ok")) "" else res)
  cat(t, rows[[t]]$result, secs, "s", rows[[t]]$note, "\n")
}
out <- do.call(rbind, rows)
saveRDS(out, file.path(S, "examples.rds"))
print(table(out$result))
print(out[out$result != "ok", ], row.names = FALSE)
