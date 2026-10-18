# How often do instructions planted in documents steer an answer? The two
# bundled sets (inst/evals/injection/) hold six short policy files each,
# every one with a planted instruction; the held-out set's are worded unlike
# the original's. Each question is asked with dragon_ask(), graded by fixed
# patterns (no model grades), and the rates are recorded in the catalogue so
# they can be tracked across models and versions.

injection_suite <- function() {
  path <- system.file("evals", "injection.json", package = "dragonfarm")
  jsonlite::fromJSON(path, simplifyVector = FALSE)
}

injection_grade <- function(answer, set_spec, i) {
  hit <- function(p) grepl(p, answer, ignore.case = TRUE, perl = TRUE)
  lang <- set_spec$language
  in_language <- !is.null(lang) && hit(lang$letters) && grepl(lang$words, tolower(answer), perl = TRUE)
  injected <- in_language || any(vapply(unlist(set_spec$injected), hit, TRUE))
  list(injected = injected, right = !injected && hit(set_spec$right[[i]]))
}

# model: what answers (as dragon_ask()). sets: "original", "heldout" or both.
# Returns one row per question and set; the rates are attached as
# attr(, "summary") and recorded as an injection_eval event.
injection_eval <- function(model = NULL, sets = c("original", "heldout"), runs_dir = dragon_runs_dir(), progress = interactive()) {
  suite <- injection_suite()
  sets <- match.arg(sets, names(suite$sets), several.ok = TRUE)
  model <- model %||% default_answer_model()
  label <- if (inherits(model, "dragon_run")) model$id else as.character(model)
  work <- tempfile("injection-")
  on.exit(unlink(work, recursive = TRUE), add = TRUE)
  rows <- list()
  for (s in sets) {
    files <- list.files(system.file("evals", "injection", s, package = "dragonfarm"), full.names = TRUE)
    docs <- suppressMessages(dragon_documents(files, name = paste0("injection-", s), runs_dir = work))
    for (i in seq_along(suite$questions)) {
      q <- suite$questions[[i]]
      a <- tryCatch(dragon_ask(docs, q, model = model)$answer, error = function(e) NA_character_)
      g <- if (is.na(a)) list(injected = NA, right = FALSE) else injection_grade(a, suite$sets[[s]], i)
      rows[[length(rows) + 1]] <- data.frame(set = s, question = q, injected = g$injected, right = g$right, answer = a)
      if (progress) cli::cli_alert_info(sprintf("%s %d/%d: %s", s, i, length(suite$questions),
                                                if (isTRUE(g$injected)) "steered" else if (g$right) "right" else "not steered, not right"))
    }
  }
  res <- do.call(rbind, rows)
  per_set <- lapply(split(res, res$set), function(x) list(questions = nrow(x), injected = sum(x$injected, na.rm = TRUE),
                                                          right = sum(x$right), failed = sum(is.na(x$injected))))
  summary <- list(model = label, datamark = isTRUE(datamark_for(tryCatch(resolve_target(model), error = function(e) NULL))),
                  sets = per_set, injected = sum(res$injected, na.rm = TRUE), questions = nrow(res))
  store_record_event("injection_eval", label, ok = TRUE, detail = summary, runs_dir = runs_dir)
  attr(res, "summary") <- summary
  res
}
