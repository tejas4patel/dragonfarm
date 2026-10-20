# A qualification report: checks that dragonfarm is installed as specified
# (installation) and that its controls work (operation), run on throwaway
# data, written as a dated Markdown report with every check, its result and
# its evidence. The report's SHA-256 is recorded in the catalogue. It shows
# the state of one machine at one time; it is evidence for a validation, not
# a validation.

qual_check <- function(area, name, expr) {
  t0 <- Sys.time()
  res <- tryCatch(expr, error = function(e) list(ok = FALSE, evidence = paste("error:", conditionMessage(e))))
  data.frame(area = area, check = name, result = if (isTRUE(res$ok)) "PASS" else if (is.na(res$ok)) "INFO" else "FAIL",
             evidence = res$evidence %||% "", seconds = round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 2))
}

qualification_checks <- function(runs_dir = dragon_runs_dir()) {
  rows <- list()
  add <- function(...) rows[[length(rows) + 1]] <<- qual_check(...)

  # Installation -----------------------------------------------------------
  add("Installation", "R and dragonfarm versions", list(ok = NA,
      evidence = sprintf("R %s; dragonfarm %s", getRversion(), utils::packageVersion("dragonfarm"))))
  add("Installation", "Python packages match the lock", {
    py <- tryCatch(dragon_python(quiet = TRUE), error = function(e) NULL)
    if (is.null(py)) list(ok = NA, evidence = "Python not set up on this machine (needed only for models)") else {
      inst <- python_packages(py)
      d <- lock_drift(inst)
      list(ok = nrow(d) == 0, evidence = if (nrow(d)) paste(d$package, d$installed, "(locked", d$locked, ")", collapse = "; ")
                                           else sprintf("%d locked packages checked", length(intersect(names(inst), names(lock_pins())))))
    }
  })
  add("Installation", "Model presets pinned to exact versions", {
    p <- dragon_presets()
    unpinned <- p$id[is.na(p$revision) | !nzchar(p$revision)]
    list(ok = !length(unpinned), evidence = if (length(unpinned)) paste("not pinned:", paste(unpinned, collapse = ", "))
                                             else sprintf("%d presets pinned to a commit", nrow(p)))
  })
  add("Installation", "Safetensors only", list(ok = !allow_pickle_weights(),
      evidence = if (allow_pickle_weights()) "pickle weights allowed by option" else "pickle weights refused"))
  add("Installation", "Catalogue schema", {
    con <- store_open(runs_dir)
    v <- store_get(con, "SELECT value FROM meta WHERE key = 'schema_version'")$value
    list(ok = identical(as.integer(v), store_schema_version),
         evidence = sprintf("schema %s on %s", v, if (store_is_pg(con)) "Postgres" else "SQLite"))
  })
  add("Installation", "Keychain for service keys", list(ok = NA,
      evidence = if (keychain_available()) "available" else "not available (keys only from the environment)"))

  # Operation, on throwaway data ------------------------------------------------
  tmp <- tempfile("qualify-")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  local_shared <- getOption("dragonfarm.catalog")
  options(dragonfarm.catalog = NULL)
  on.exit(options(dragonfarm.catalog = local_shared), add = TRUE)
  add("Operation", "The record refuses edits and deletions", {
    con <- store_open(tmp)
    store_record_event("qualification", "probe", ok = TRUE, runs_dir = tmp)
    upd <- tryCatch({ DBI::dbExecute(con, "UPDATE events SET ok = 0"); "changed" }, error = function(e) "refused")
    del <- tryCatch({ DBI::dbExecute(con, "DELETE FROM events"); "deleted" }, error = function(e) "refused")
    list(ok = upd == "refused" && del == "refused", evidence = sprintf("update %s, delete %s", upd, del))
  })
  add("Operation", "The policy is sound", {
    p <- policy_current(runs_dir)
    probs <- policy_problems(p)
    list(ok = !length(probs), evidence = if (length(probs)) paste(probs, collapse = "; ") else sprintf("policy version %d", p$version))
  })
  add("Operation", "Tool contracts are valid", {
    reg <- tool_registry(refresh = TRUE)
    bad <- Filter(length, lapply(reg, tool_contract_problems))
    list(ok = length(reg) > 0 && !length(bad),
         evidence = if (length(bad)) paste(sprintf("%s: %s", names(bad), vapply(bad, paste, "", collapse = ", ")), collapse = "; ")
                    else sprintf("%d tools, every contract complete: %s", length(reg), paste(sort(names(reg)), collapse = ", ")))
  })
  add("Operation", "An agent outside its policy is refused", {
    r <- withr::with_options(list(dragonfarm.runs_dir = tmp), tool_call("train_model", list(questions = "x", model = "m"), agent = "answer"))
    list(ok = identical(r$code, "NOT_ALLOWED"), evidence = paste("answer agent asked to train:", r$code))
  })
  add("Operation", "Training waits for a person", {
    r <- withr::with_options(list(dragonfarm.runs_dir = tmp), tool_call("train_model", list(questions = "x", model = "m"), agent = "trainer"))
    list(ok = identical(r$code, "NEEDS_APPROVAL"), evidence = paste("trainer agent asked to train:", r$code))
  })
  add("Operation", "A blocked outbound call sends nothing", {
    pol <- policy_default(); pol$outbound$allowed_hosts <- list()
    policy_set(pol, set_by = "qualification", note = "probe", runs_dir = tmp)
    blocked <- tryCatch({ outbound_check("https://example.com", "probe", runs_dir = tmp); FALSE },
                        dragonfarm_error = function(e) identical(e$code, "NOT_ALLOWED"))
    list(ok = blocked, evidence = if (blocked) "refused with NOT_ALLOWED before sending" else "not refused")
  })
  add("Operation", "Governed mode refuses an unapproved trained model", {
    gov <- file.path(tmp, "governed"); dir.create(gov)
    pol <- policy_default(); pol$registry$governed <- TRUE
    policy_set(pol, set_by = "qualification", note = "probe", runs_dir = gov)
    target <- list(model = "probe-base", adapter = file.path(gov, "probe-run", "adapter"))
    code <- tryCatch({ serving_check(target, gov); "allowed" }, dragonfarm_error = function(e) e$code)
    untrained <- tryCatch({ serving_check(list(model = "probe-base", adapter = NULL), gov); "allowed" }, dragonfarm_error = function(e) e$code)
    list(ok = identical(code, "NOT_APPROVED") && identical(untrained, "allowed"),
         evidence = sprintf("unapproved run: %s; untrained model: %s", code, untrained))
  })
  add("Operation", "A judge saved for a background job holds no key", {
    # A probe key made now, so it appears in no source file (an installed
    # package can carry its source with each function).
    probe <- paste0("sk-ant-", paste(sample(c(letters, 0:9), 24, TRUE), collapse = ""))
    old <- Sys.getenv("ANTHROPIC_API_KEY", unset = NA)
    Sys.setenv(ANTHROPIC_API_KEY = probe)
    on.exit(if (is.na(old)) Sys.unsetenv("ANTHROPIC_API_KEY") else Sys.setenv(ANTHROPIC_API_KEY = old), add = TRUE)
    leaked <- length(grepRaw(probe, serialize(dragon_judge_anthropic(), NULL), fixed = TRUE)) > 0
    list(ok = !leaked, evidence = if (leaked) "the saved judge contains the key" else "the saved judge contains no key")
  })
  add("Operation", "Personal-data patterns", {
    planted <- c("mail jane.doe@hospital.org", "call (617) 555-0142", "SSN 123-45-6789", "Patient ID: AB-77231",
                 "card 4111 1111 1111 1111", "DOB: 03/14/1962")
    lookalike <- c("version 4.12.2", "$249,625 million", "revised 2021-05-01", "DOI 10.1080/01621459.2021.1981338",
                   "order 1234 5678 9012 3456", "approved 03/14/1962")
    found <- vapply(planted, function(x) nrow(pii_find(x)) > 0, TRUE)
    false <- vapply(lookalike, function(x) nrow(pii_find(x)) > 0, TRUE)
    list(ok = all(found) && !any(false), evidence = sprintf("%d of %d planted found; %d of %d look-alikes flagged",
                                                             sum(found), length(found), sum(false), length(false)))
  })
  add("Operation", "Answer grading rules", {
    ok <- eval_grade(list(all = list("30 days")), "Within 30 days [1].") &&
      eval_grade(list(declines = TRUE), "The documents do not directly provide this.") &&
      !eval_grade(list(declines = TRUE), "It costs $99.")
    list(ok = ok, evidence = "pattern, decline and non-decline cases")
  })
  store_close_all()
  do.call(rbind, rows)
}

# Run the checks and write the report. Returns list(file, sha256 (md5 without openssl), passed, failed).
qualification_report <- function(file, runs_dir = dragon_runs_dir()) {
  checks <- qualification_checks(runs_dir)
  who <- current_user() %||% "unknown"
  lines <- c(
    "# dragonfarm qualification report", "",
    sprintf("- Run by: %s", who), sprintf("- Run at: %s (UTC)", now_utc()),
    sprintf("- Machine: %s, %s", Sys.info()[["sysname"]], Sys.info()[["release"]]),
    sprintf("- Runs folder: %s", normalizePath(runs_dir, winslash = "/", mustWork = FALSE)),
    sprintf("- Result: %d passed, %d failed, %d for information", sum(checks$result == "PASS"), sum(checks$result == "FAIL"),
            sum(checks$result == "INFO")), "",
    "This report shows the state of one machine at one time. It is evidence for a validation, not a validation.", "",
    "| Area | Check | Result | Evidence |", "|---|---|---|---|",
    sprintf("| %s | %s | %s | %s |", checks$area, checks$check, checks$result, gsub("[|]", "/", checks$evidence))
  )
  writeLines(lines, file, useBytes = TRUE)
  digest <- file_digest(file)
  store_record_event("qualification", basename(file), ok = !any(checks$result == "FAIL"),
                     detail = c(list(passed = sum(checks$result == "PASS"), failed = sum(checks$result == "FAIL")), digest),
                     runs_dir = runs_dir)
  c(list(file = file), digest, list(passed = sum(checks$result == "PASS"), failed = sum(checks$result == "FAIL"), checks = checks))
}
