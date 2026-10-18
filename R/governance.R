# Governance checks (T7): the base model's licence, where a run came from,
# and what deleting a run or a document set would affect. All read-only and
# deterministic, so a person or an auditor gets the same answer every time.

# Licences that allow commercial use with attribution and impose no use
# restrictions of their own. Anything else named is "check its terms".
permissive_licences <- c("apache-2.0", "mit", "bsd-2-clause", "bsd-3-clause", "cc-by-4.0", "cc0-1.0",
                         "bsl-1.0", "unlicense", "isc", "zlib")

licence_id <- function(x) {
  x <- tolower(trimws(paste(unlist(x), collapse = " ")))
  switch(x, "apache 2.0" = "apache-2.0", "llama 3.2" = "llama3.2", "qwen research" = "qwen-research", gsub("[[:space:]]+", "-", x))
}

licence_result <- function(model, licence, from) {
  id <- licence_id(licence)
  kind <- if (!nzchar(id) || id %in% c("unknown", "na")) "unknown" else if (id %in% permissive_licences) "permissive" else "check_terms"
  note <- switch(kind,
    permissive = sprintf("A permissive open licence (%s).", id),
    check_terms = sprintf("Its licence (%s) has terms of its own. Read them before using the model or what you train from it in a product.", id),
    unknown = "No licence found. Check the model's page before using it beyond trying it out.")
  list(model = model, licence = if (identical(kind, "unknown")) NULL else id, kind = kind, from = from, note = note)
}

# The `license:` line of a model card's front matter.
card_licence <- function(readme) {
  if (!file.exists(readme)) return(NULL)
  lines <- readLines(readme, n = 60, warn = FALSE, encoding = "UTF-8")
  if (!length(lines) || !identical(trimws(lines[1]), "---")) return(NULL)
  end <- which(trimws(lines[-1]) == "---")[1]
  if (is.na(end)) return(NULL)
  hit <- grep("^license:", lines[2:end], value = TRUE)
  if (length(hit)) trimws(gsub("[\"']", "", sub("^license:", "", hit[1]))) else NULL
}

# The licence of a base model: the preset list first, then a local folder's
# model card, then (only when `lookup` is TRUE and the policy allows it) the
# Hugging Face Hub, through the outbound check. Never throws.
model_licence <- function(model, revision = NULL, lookup = FALSE, runs_dir = dragon_runs_dir()) {
  preset <- preset_for(model)
  if (!is.null(preset)) return(licence_result(model, preset$license, "preset list"))
  if (dir.exists(model)) {
    lic <- card_licence(file.path(model, "README.md"))
    return(licence_result(model, lic %||% "unknown", if (is.null(lic)) "local folder (no model card)" else "local model card"))
  }
  if (!isTRUE(lookup)) return(licence_result(model, "unknown", "not looked up"))
  if (isTRUE(policy_current(runs_dir)$outbound$offline)) return(licence_result(model, "unknown", "not looked up (offline)"))
  if (!requireNamespace("httr2", quietly = TRUE)) return(licence_result(model, "unknown", "not looked up (needs httr2)"))
  url <- sprintf("https://huggingface.co/api/models/%s%s", model, if (!is.null(revision)) paste0("/revision/", revision) else "")
  info <- tryCatch({
    outbound_check(url, "look up a model's licence", runs_dir = runs_dir)
    resp <- httr2::req_perform(httr2::req_timeout(httr2::request(url), 20))
    httr2::resp_body_json(resp)
  }, error = function(e) NULL)
  if (is.null(info)) return(licence_result(model, "unknown", "Hugging Face Hub (no answer)"))
  lic <- info$cardData$license %||% sub("^license:", "", grep("^license:", unlist(info$tags), value = TRUE)[1])
  licence_result(model, if (length(lic) && !is.na(lic[1])) lic else "unknown", "Hugging Face Hub")
}

# The document set a training set came from, when it was built from one.
run_documents <- function(run) {
  meta <- tryCatch(read_json(run_path(run, "dataset.json")), error = function(e) list())
  if (!is.null(meta$documents)) return(meta$documents)
  # A training file saved next to its questions (<set>/questions/x-training.jsonl).
  src <- meta$source %||% ""
  if (grepl("/questions/[^/]+[.]jsonl$", src) && file.exists(file.path(dirname(dirname(src)), "manifest.json"))) {
    dir <- dirname(dirname(src))
    m <- tryCatch(read_json(file.path(dir, "manifest.json")), error = function(e) list())
    return(list(set = m$name %||% basename(dir), dir = dir, questions = sub("-training[.]jsonl$", ".jsonl", src)))
  }
  NULL
}

run_in <- function(run, runs_dir) {
  if (inherits(run, "dragon_run")) return(run)
  if (is.character(run) && length(run) == 1 && !dir.exists(run) && dir.exists(file.path(runs_dir, run))) run <- file.path(runs_dir, run)
  dragon_run(run)
}

file_md5 <- function(p) if (length(p) && nzchar(p) && file.exists(p)) unname(tools::md5sum(p)) else NA_character_

# Where a run came from: who started it, the base model and its licence,
# the exact data (with fingerprints), the documents behind it and their
# version, any personal-data approval, its evaluation and its sign-offs.
provenance_report <- function(run, runs_dir = dragon_runs_dir()) {
  run <- run_in(run, runs_dir)
  cfg <- run_config(run)
  meta <- tryCatch(read_json(run_path(run, "dataset.json")), error = function(e) list())
  st <- tryCatch(dragon_status(run), error = function(e) list())
  con <- store_open(runs_dir)
  created <- store_get(con, "SELECT at, actor, detail FROM events WHERE kind = 'run_created' AND name = ? ORDER BY id LIMIT 1",
                       params = list(run$id))
  created_detail <- if (nrow(created) && !is.na(created$detail[1])) jsonlite::fromJSON(created$detail[1], simplifyVector = FALSE) else list()
  docs <- run_documents(run)
  if (!is.null(docs)) {
    v <- if (!is.null(docs$chunks_md5)) store_get(con, "SELECT version FROM set_versions WHERE set_name = ? AND chunks_md5 = ?",
                                                 params = list(docs$set, docs$chunks_md5))$version
    latest <- store_get(con, "SELECT version, chunks_md5 FROM set_versions WHERE set_name = ? ORDER BY version DESC LIMIT 1",
                        params = list(docs$set))
    docs$version <- if (length(v)) as.integer(v[1]) else NA_integer_
    docs$current <- if (nrow(latest) && !is.null(docs$chunks_md5)) identical(latest$chunks_md5[1], docs$chunks_md5) else NA
  }
  reg <- registry_list(runs_dir = runs_dir)
  reg <- reg[reg$run_id == run$id, c("name", "version", "status", "signer", "signed_at"), drop = FALSE]
  list(
    run = run$id, state = st$state %||% "unknown", created_at = cfg$created_at,
    started_by = if (nrow(created)) created$actor[1] else NA_character_, stage = cfg$stage %||% "sft",
    model = list(id = cfg$model$id, revision = cfg$model$revision %||% NA_character_,
                 trust_remote_code = isTRUE(cfg$model$trust_remote_code), allow_pickle = isTRUE(cfg$model$allow_pickle),
                 base_run = cfg$model$base_run %||% NA_character_),
    licence = model_licence(cfg$model$id, runs_dir = runs_dir),
    data = list(name = meta$name %||% NA_character_, source = meta$source %||% NA_character_,
                prompt = meta$mapping$prompt %||% NA_character_, response = meta$mapping$response %||% NA_character_,
                n_train = cfg$data$n_train, n_eval = cfg$data$n_eval,
                train_md5 = file_md5(if (!is.null(cfg$data$train)) run_path(run, cfg$data$train)),
                eval_md5 = file_md5(if (!is.null(cfg$data$eval)) run_path(run, cfg$data$eval))),
    documents = docs,
    personal_data = created_detail[["personal_data"]],
    personal_data_rows = created_detail[["personal_data_rows"]],
    evaluation = run_evaluation(run),
    registry = reg
  )
}

provenance_text <- function(p) {
  yn <- function(x) if (isTRUE(x)) "yes" else "no"
  na <- function(x) if (is.null(x) || (length(x) == 1 && is.na(x))) "not recorded" else as.character(x)
  tpl <- function(x) if (is.null(x) || is.na(x)) "not recorded" else paste0("`", gsub("\n", "\\n", x, fixed = TRUE), "`")   # one line, as typed
  lines <- c(
    sprintf("# Provenance of run %s", p$run), "",
    sprintf("- State: %s; stage: %s; created %s %s", p$state, p$stage, na(p$created_at),
            if (is.na(p$started_by)) "(who created it is not recorded)" else paste("by", p$started_by)),
    sprintf("- Base model: %s at revision %s", p$model$id, na(p$model$revision)),
    sprintf("- Continues from run: %s", if (is.na(p$model$base_run)) "none (trained from the base model)" else p$model$base_run),
    sprintf("- Remote code allowed: %s; pickle weights allowed: %s", yn(p$model$trust_remote_code), yn(p$model$allow_pickle)),
    sprintf("- Licence: %s (%s). %s", na(p$licence$licence), p$licence$from, p$licence$note), "",
    "## Data",
    sprintf("- %s, from %s", na(p$data$name), na(p$data$source)),
    sprintf("- Prompt: %s; response: %s", tpl(p$data$prompt), tpl(p$data$response)),
    sprintf("- %s training rows (md5 %s), %s held out (md5 %s)", na(p$data$n_train), na(p$data$train_md5), na(p$data$n_eval), na(p$data$eval_md5)),
    if (!is.null(p$documents)) sprintf("- Documents: set %s, version %s (%s)%s", p$documents$set, na(p$documents$version),
                                       if (isTRUE(p$documents$current)) "still the current version" else if (isFALSE(p$documents$current)) "the set has been re-read since" else "version not known",
                                       if (!is.null(p$documents$questions)) paste0("; questions ", basename(p$documents$questions)) else ""),
    if (!is.null(p[["personal_data"]])) sprintf("- Personal data: %s rows with hits; training approved by %s", na(p[["personal_data"]]$rows), na(p[["personal_data"]]$approved_by))
    else if (isTRUE(p$personal_data_rows > 0)) sprintf("- Personal data: %d rows with hits; no approval recorded (started from R code)", as.integer(p$personal_data_rows))
    else if (identical(as.integer(p$personal_data_rows), 0L)) "- Personal data: none found when the run was created"
    else "- Personal data: not recorded (the run predates this check)", "",
    "## Evaluation",
    if (length(p$evaluation)) sprintf("- %s: %s", names(p$evaluation), vapply(p$evaluation, function(x) if (is.list(x)) "see the run folder" else format(x, digits = 4), ""))
    else "- None yet", "",
    "## Model versions",
    if (nrow(p$registry)) sprintf("- %s version %d: %s%s", p$registry$name, as.integer(p$registry$version), p$registry$status,
                                  ifelse(is.na(p$registry$signer), "", paste0(" (", p$registry$signer, ", ", p$registry$signed_at, ")")))
    else "- Not proposed as a model version"
  )
  paste(lines, collapse = "\n")
}

# What deleting something would affect. For a run: the runs that continue
# from it and its model versions. For a document set: the question files in
# it, the runs trained from it and their model versions. Approved versions
# are called out, since serving depends on them.
deletion_impact <- function(run = NULL, set = NULL, runs_dir = dragon_runs_dir()) {
  if (is.null(run) == is.null(set)) cli::cli_abort("Name a run or a document set, not both.", class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  reg <- registry_list(runs_dir = runs_dir)
  versions_of <- function(ids) reg[reg$run_id %in% ids, c("name", "version", "run_id", "status"), drop = FALSE]
  if (!is.null(run)) {
    r <- run_in(run, runs_dir)
    ids <- run_children(r$id, runs_dir)
    v <- versions_of(r$id)
    out <- list(kind = "run", target = r$id, question_files = 0L, runs = as.list(ids), versions = v)
  } else {
    docs <- dragon_documents_load(set, runs_dir = runs_dir)
    q <- list.files(file.path(docs$dir, "questions"), pattern = "[.]jsonl$")
    q <- q[!grepl("-training[.]jsonl$", q)]
    all <- dragon_runs(runs_dir)
    ids <- if (nrow(all)) all$id[vapply(all$dir, function(d) identical(run_documents(dragon_run(d))$set, docs$name), TRUE)] else character()
    v <- versions_of(ids)
    out <- list(kind = "set", target = docs$name, question_files = length(q), runs = as.list(ids), versions = v)
  }
  approved <- sum(v$status == "approved")
  out$approved_versions <- approved
  out$note <- impact_note(out)
  out
}

impact_note <- function(x) {
  n_runs <- length(x$runs)
  parts <- c(
    if (x$question_files) sprintf("%d question file%s", x$question_files, if (x$question_files == 1) "" else "s"),
    if (n_runs) sprintf("%d run%s %s", n_runs, if (n_runs == 1) "" else "s", if (identical(x$kind, "run")) "continuing from it" else "trained from it"),
    if (nrow(x$versions)) sprintf("%d model version%s", nrow(x$versions), if (nrow(x$versions) == 1) "" else "s"))
  if (!length(parts)) return("Nothing else depends on it.")
  s <- sprintf("Depends on it: %s.", paste(parts, collapse = ", "))
  if (x$approved_versions) s <- paste(s, sprintf("%d of those model versions %s approved, so answers in governed mode depend on it.",
                                                  x$approved_versions, if (x$approved_versions == 1) "is" else "are"))
  s
}

# What a person should know before signing a model version off (G6, as a
# fixed check rather than an agent). Each finding is "ok", "look" (worth
# reading before signing) or "unknown" (not recorded). Nothing here blocks:
# the findings are shown next to the sign-off and stored with it.
governance_findings <- function(run, runs_dir = dragon_runs_dir()) {
  p <- provenance_report(run, runs_dir = runs_dir)
  f <- function(check, status, note) data.frame(check = check, status = status, note = note, stringsAsFactors = FALSE)
  out <- list(
    f("licence", if (identical(p$licence$kind, "permissive")) "ok" else if (identical(p$licence$kind, "check_terms")) "look" else "unknown",
      p$licence$note),
    if (!is.null(p[["personal_data"]])) f("personal_data", "look", sprintf("Trained on %s rows with likely personal data, approved by %s.",
                                                                     p[["personal_data"]]$rows %||% "some", p[["personal_data"]]$approved_by %||% "someone"))
    else if (isTRUE(p$personal_data_rows > 0)) f("personal_data", "look", sprintf("Trained on %d rows with likely personal data; no approval recorded (started from R code).", as.integer(p$personal_data_rows)))
    else if (identical(as.integer(p$personal_data_rows), 0L)) f("personal_data", "ok", "No personal data was found in the training rows.")
    else f("personal_data", "unknown", "Not recorded: the run predates this check."),
    if (!is.null(p$documents)) {
      if (isFALSE(p$documents$current)) f("documents", "look", sprintf("The document set %s has been re-read since training; answers may cite text that has changed.", p$documents$set))
      else if (isTRUE(p$documents$current)) f("documents", "ok", sprintf("Trained on the current version of the document set %s.", p$documents$set))
      else f("documents", "unknown", sprintf("The version of the document set %s it was trained on is not known.", p$documents$set))
    },
    if (isTRUE(p$model$trust_remote_code)) f("remote_code", "look", "The base model runs its own code when loaded (remote code allowed)."),
    if (!length(p$evaluation)) f("evaluation", "look", "No evaluation recorded."),
    if (is.na(p$started_by)) f("creator", "unknown", "Who created the run is not recorded.")
  )
  do.call(rbind, Filter(Negate(is.null), out))
}
