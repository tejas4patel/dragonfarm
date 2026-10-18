# Model registry. A finished, evaluated run can be proposed as a numbered
# version of a named model; only a person can sign a version off for use,
# reject it, or retire it later. Each sign-off records its meaning ("approved
# for answering questions on the FDA guidances"), who signed and when.
# Versions and sign-offs are append-only, like the event log, so the history
# of what was approved cannot be rewritten (D-8: a person approves every
# promotion).

registry_status_levels <- c("candidate", "approved", "rejected", "retired")

# Evidence a run was evaluated: held-out loss, task metrics or a judge.
run_evaluation <- function(run) {
  st <- tryCatch(dragon_status(run), error = function(e) list())
  ev <- list(eval_loss = st$eval_loss, perplexity = st$perplexity, pref_accuracy = st$pref_accuracy,
             reward_mean = st$reward_mean)
  for (f in c("metrics.json", "judge.json")) {
    p <- run_path(run, f)
    if (file.exists(p)) ev[[sub("[.]json$", "", f)]] <- tryCatch(read_json(p), error = function(e) NULL)
  }
  Filter(Negate(is.null), ev)
}

# Fingerprint of what the run was trained on.
run_data_md5 <- function(run) {
  cfg <- tryCatch(read_json(run_path(run, "config.json")), error = function(e) list())
  f <- cfg$data$train
  p <- if (!is.null(f)) file.path(run$dir, f) else ""
  if (nzchar(p) && file.exists(p)) unname(tools::md5sum(p)) else NA_character_
}

# Propose a run as the next version of `name`. Returns list(name, version).
registry_propose <- function(run, name, proposed_by = NULL, runs_dir = dragon_runs_dir()) {
  check_string(name, "name")
  if (!grepl("^[A-Za-z0-9][A-Za-z0-9._-]*$", name)) {
    cli::cli_abort("A model name uses letters, digits, dots, dashes and underscores.", class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  run <- dragon_run(run)
  st <- dragon_status(run)
  if (!identical(st$state, "succeeded")) {
    cli::cli_abort("Run {.strong {run$id}} has not succeeded ({st$state}); only finished runs can be proposed.",
                   class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  evaluation <- run_evaluation(run)
  if (!length(evaluation)) {
    cli::cli_abort(c("Run {.strong {run$id}} has no evaluation, so it cannot be proposed.",
                     "i" = "Evaluate it first: held-out loss, task metrics or a judge."),
                   class = "dragonfarm_error", code = "NOT_EVALUATED")
  }
  cfg <- tryCatch(read_json(run_path(run, "config.json")), error = function(e) list())
  con <- store_open(runs_dir)
  v <- store_get(con, "SELECT COALESCE(MAX(version), 0) AS v FROM model_versions WHERE name = ?", params = list(name))$v + 1L
  proposed_by <- proposed_by %||% Sys.info()[["user"]] %||% NA_character_
  store_exec(con, paste("INSERT INTO model_versions (name, version, run_id, run_dir, base_model, revision, data_md5,",
                            "evaluation, proposed_by, proposed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"),
                 params = list(name, v, run$id, run$dir, cfg$model$id %||% NA_character_, cfg$model$revision %||% NA_character_,
                               run_data_md5(run), as.character(jsonlite::toJSON(evaluation, auto_unbox = TRUE, null = "null")),
                               proposed_by, now_utc()))
  store_record_event("model_proposed", sprintf("%s v%d", name, v), ok = TRUE,
                     detail = list(run = run$id, proposed_by = proposed_by), runs_dir = runs_dir)
  list(name = name, version = v, status = "candidate")
}

# A person's decision on a version. `meaning` says what the signature means
# (what the model is approved for, or why it is rejected or retired).
registry_sign_off <- function(name, version, decision = c("approved", "rejected", "retired"), meaning,
                              signer = Sys.info()[["user"]], runs_dir = dragon_runs_dir()) {
  decision <- match.arg(decision)
  check_string(meaning, "meaning")
  if (!nzchar(trimws(meaning))) {
    cli::cli_abort("Say what the sign-off means.", class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  con <- store_open(runs_dir)
  row <- store_get(con, "SELECT * FROM model_versions WHERE name = ? AND version = ?", params = list(name, as.integer(version)))
  if (!nrow(row)) {
    cli::cli_abort("There is no version {version} of {.val {name}}.", class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  now <- registry_status(name, version, runs_dir)
  allowed <- switch(now, candidate = c("approved", "rejected"), approved = "retired", character())
  if (!decision %in% allowed) {
    cli::cli_abort("{.val {name}} version {version} is {now}; it cannot be {decision}.",
                   class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  policy <- policy_current(runs_dir)
  if (isTRUE(policy$registry$separate_signer) && identical(signer, row$proposed_by)) {
    cli::cli_abort("The policy needs someone other than the proposer ({row$proposed_by}) to sign off.",
                   class = "dragonfarm_error", code = "NOT_ALLOWED")
  }
  store_exec(con, "INSERT INTO model_signoffs (name, version, decision, meaning, signer, signed_at) VALUES (?, ?, ?, ?, ?, ?)",
                 params = list(name, as.integer(version), decision, meaning, signer, now_utc()))
  store_record_event("model_signoff", sprintf("%s v%d", name, as.integer(version)), ok = TRUE,
                     detail = list(decision = decision, meaning = meaning, signer = signer), runs_dir = runs_dir)
  invisible(decision)
}

registry_status <- function(name, version, runs_dir = dragon_runs_dir()) {
  d <- store_get(store_open(runs_dir), "SELECT decision FROM model_signoffs WHERE name = ? AND version = ? ORDER BY id DESC LIMIT 1",
                       params = list(name, as.integer(version)))$decision
  if (length(d)) d else "candidate"
}

# Every version with its current status and latest sign-off.
registry_list <- function(name = NULL, runs_dir = dragon_runs_dir()) {
  con <- store_open(runs_dir)
  sql <- paste("SELECT v.name, v.version, v.run_id, v.base_model, v.revision, v.proposed_by, v.proposed_at,",
               "s.decision, s.meaning, s.signer, s.signed_at FROM model_versions v LEFT JOIN model_signoffs s",
               "ON s.id = (SELECT MAX(id) FROM model_signoffs WHERE name = v.name AND version = v.version)",
               if (!is.null(name)) "WHERE v.name = ?", "ORDER BY v.name, v.version")
  out <- store_get(con, sql, params = if (!is.null(name)) list(name) else NULL)
  out$status <- ifelse(is.na(out$decision), "candidate", out$decision)
  out
}

# The approved version to use for a name: the newest one approved and not retired.
registry_approved <- function(name, runs_dir = dragon_runs_dir()) {
  l <- registry_list(name, runs_dir)
  l <- l[l$status == "approved", , drop = FALSE]
  if (!nrow(l)) return(NULL)
  l[which.max(l$version), , drop = FALSE]
}

# Governed mode (registry.governed in the policy): a trained run answers
# people (Ask, Chat, the answer tool) only when it is the run behind an
# approved, not retired, model version. Untrained models are not affected,
# and neither are Try it and evaluation, where a candidate is checked before
# anyone approves it.
serving_check <- function(target, runs_dir = dragon_runs_dir()) {
  if (is.null(target)) return(invisible(TRUE))
  # A run's adapter (<run>/adapter) or its merged copy in the default place
  # (<run>/merged). A merged copy saved elsewhere cannot be traced to its run.
  merged <- is.null(target$adapter) && is.character(target$model) && dir.exists(target$model) &&
    identical(basename(target$model), "merged") && file.exists(file.path(dirname(target$model), "config.json"))
  if (is.null(target$adapter) && !merged) return(invisible(TRUE))
  policy <- tryCatch(policy_current(runs_dir), error = function(e) NULL)
  if (!isTRUE(policy$registry$governed)) return(invisible(TRUE))
  run_id <- basename(dirname(if (merged) target$model else target$adapter))
  l <- tryCatch(registry_list(runs_dir = runs_dir), error = function(e) NULL)
  if (!is.null(l) && any(l$run_id == run_id & l$status == "approved")) return(invisible(TRUE))
  cli::cli_abort(c("{.val {run_id}} is not an approved model version, and only approved versions answer in governed mode.",
                   "i" = "Propose it and have it signed off in Monitor, Model versions, or answer with an untrained model."),
                 class = "dragonfarm_error", code = "NOT_APPROVED")
}
