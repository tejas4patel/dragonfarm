# Run an article's code for real, chunk by chunk, in one R session: the
# articles are built with eval = FALSE, so nothing else checks that their code
# still works. Runs in a scratch folder, with the runs folder pointed there
# (a chunk that sets dragonfarm.runs_dir is redirected, so nothing is written
# to your home folder). Output lines shown in the article ("#>") are dropped
# and each chunk's printed output is saved next to it for comparing.
#   Rscript scripts/run_article.R vignettes/quickstart.Rmd [out dir] [skip pattern]
args <- commandArgs(trailingOnly = TRUE)
rmd <- normalizePath(args[[1]])
S <- if (length(args) > 1) args[[2]] else tempfile("article-")
skip <- if (length(args) > 2) args[[3]] else "dragon_llm_anthropic|ANTHROPIC|dragon_publish|kaggle|lightning|ollama"
dir.create(S, showWarnings = FALSE, recursive = TRUE)
pkg <- normalizePath(".")
lines <- readLines(rmd, warn = FALSE, encoding = "UTF-8")
starts <- grep("^```\\{r", lines)
chunks <- lapply(starts, function(s) {
  e <- s + which(grepl("^```\\s*$", lines[(s + 1):length(lines)]))[1]
  list(header = lines[s], code = lines[(s + 1):(e - 1)], line = s)
})
chunks <- Filter(function(ch) !grepl("include\\s*=\\s*FALSE", ch$header), chunks)
devtools::load_all(pkg, quiet = TRUE)
runs <- file.path(S, "runs")
options(dragonfarm.runs_dir = runs)
setwd(S)
env <- new.env(parent = globalenv())
rows <- list()
for (i in seq_along(chunks)) {
  ch <- chunks[[i]]
  code <- ch$code[!grepl("^#>", ch$code)]
  code <- sub("options\\(dragonfarm\\.runs_dir = [^)]*\\)", "options(dragonfarm.runs_dir = runs)", code)
  if (any(grepl(skip, code, ignore.case = TRUE))) {
    rows[[i]] <- data.frame(chunk = i, line = ch$line, result = "skipped", seconds = NA, error = "")
    cat("chunk", i, "(line", ch$line, ") skipped\n"); next
  }
  assign("runs", runs, envir = env)
  t0 <- Sys.time()
  out <- file.path(S, sprintf("chunk-%02d.txt", i))
  err <- tryCatch({
    utils::capture.output(withVisible_eval <- {
      exprs <- parse(text = code)
      for (e in exprs) { v <- withVisible(eval(e, env)); if (v$visible) print(v$value) }
    }, file = out, type = "output")
    ""
  }, error = function(e) conditionMessage(e))
  secs <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")))
  rows[[i]] <- data.frame(chunk = i, line = ch$line, result = if (nzchar(err)) "failed" else "ok", seconds = secs, error = substr(err, 1, 300))
  cat("chunk", i, "(line", ch$line, ")", rows[[i]]$result, secs, "s", err, "\n")
}
res <- do.call(rbind, rows)
saveRDS(res, file.path(S, "article.rds"))
print(table(res$result))
