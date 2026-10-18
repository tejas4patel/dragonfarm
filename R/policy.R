# Policy: which agent may call which tool, which calls wait for a person, and
# what an agent task may spend. Stored in the catalog as versions that are
# never edited; the first version is inst/policy/default.json. Agents can
# read the policy but no tool changes it: only policy_set(), which no agent
# can call, writes a new version.

policy_default <- function() {
  jsonlite::fromJSON(system.file("policy", "default.json", package = "dragonfarm"), simplifyVector = FALSE)
}

policy_current <- function(runs_dir = dragon_runs_dir()) {
  con <- store_open(runs_dir)
  row <- store_get(con, "SELECT version, body FROM policies ORDER BY version DESC LIMIT 1")
  if (!nrow(row)) {
    body <- policy_default()
    store_exec(con, "INSERT INTO policies (version, body, set_by, set_at) VALUES (1, ?, 'dragonfarm default', ?)",
                   params = list(as.character(jsonlite::toJSON(body, auto_unbox = TRUE, null = "null")), now_utc()))
    return(policy_effective(c(body, list(version = 1L))))
  }
  policy_effective(c(jsonlite::fromJSON(row$body, simplifyVector = FALSE), list(version = as.integer(row$version))))
}

# D-10: governed mode and the four-eyes sign-off are on by default on a
# server (Posit Connect, or a shared Postgres catalogue) and off on a single
# laptop, where one person would otherwise have to approve their own runs.
# A value an admin has saved always wins; only an unset one takes the default.
deployment_is_server <- function() {
  !is.null(store_shared()) || identical(toupper(Sys.getenv("RSTUDIO_PRODUCT")), "CONNECT") || nzchar(Sys.getenv("CONNECT_SERVER"))
}

policy_effective <- function(p) {
  server <- deployment_is_server()
  if (is.null(p$registry$governed)) p$registry$governed <- server
  if (is.null(p$registry$separate_signer)) p$registry$separate_signer <- server
  p
}

# Problems with a policy (empty when it is sound): every agent's tools must
# exist, and approval side effects must be known ones.
policy_problems <- function(policy) {
  p <- character()
  known <- names(tool_registry())
  for (a in names(policy$agents)) {
    unknown <- setdiff(unlist(policy$agents[[a]]$tools), known)
    if (length(unknown)) p <- c(p, sprintf("agent '%s' lists unknown tool '%s'", a, unknown))
  }
  sizes <- Filter(Negate(is.null), c(list(default = policy$min_model_b$default), lapply(policy$agents, `[[`, "min_model_b")))
  for (n in names(sizes)) {
    if (!is.numeric(sizes[[n]]) || length(sizes[[n]]) != 1 || is.na(sizes[[n]]) || sizes[[n]] < 0) {
      p <- c(p, sprintf("min_model_b for '%s' must be a number of billions of parameters", n))
    }
  }
  for (a in names(policy$agents)) {
    m <- policy$agents[[a]]$model
    if (!is.null(m) && !(is.character(m) && length(m) == 1 && nzchar(m))) p <- c(p, sprintf("model for '%s' must be a model id or run id", a))
  }
  if (!is.null(policy$registry$governed) && !(is.logical(policy$registry$governed) && length(policy$registry$governed) == 1 &&
                                               !is.na(policy$registry$governed))) {
    p <- c(p, "registry governed must be true or false")
  }
  for (f in c("admins", "admin_groups")) {
    v <- policy[[f]]
    if (!is.null(v) && !(is.list(v) || is.character(v)) || !all(vapply(as.list(v), function(x) is.character(x) && length(x) == 1 && nzchar(x), TRUE))) {
      p <- c(p, sprintf("%s must be a list of names", f))
    }
  }
  if (!is.null(policy$pii_allow) && !all(vapply(as.list(policy$pii_allow), function(x) is.character(x) && length(x) == 1 && nzchar(x), TRUE))) {
    p <- c(p, "pii_allow must be a list of contact patterns")
  }
  for (r in policy$access %||% list()) {
    if (!is.character(r$documents %||% "") || !length(c(unlist(r$groups), unlist(r$users)))) {
      p <- c(p, "each access rule needs documents (a file pattern) and groups or users")
    }
  }
  bad <- setdiff(unlist(policy$approvals$side_effects), tool_side_effects)
  if (length(bad)) p <- c(p, sprintf("unknown side effect '%s'", bad))
  p
}

# Write a new policy version (an admin action; not a tool). Returns the version.
policy_set <- function(policy, set_by = current_user(), note = NULL, runs_dir = dragon_runs_dir()) {
  policy$version <- NULL
  problems <- policy_problems(policy)
  if (length(problems)) cli::cli_abort(c("This policy has problems:", stats::setNames(problems, rep("x", length(problems)))))
  current <- policy_current(runs_dir)
  con <- store_open(runs_dir)
  v <- current$version + 1L
  store_exec(con, "INSERT INTO policies (version, body, set_by, set_at) VALUES (?, ?, ?, ?)",
                 params = list(v, as.character(jsonlite::toJSON(policy, auto_unbox = TRUE, null = "null")), set_by, now_utc()))
  store_record_event("policy_set", paste0("version ", v), ok = TRUE, detail = list(set_by = set_by, version = v, note = note),
                     runs_dir = runs_dir)
  invisible(v)
}

# Every policy version, newest first, with the reason given when it was saved.
policy_history <- function(runs_dir = dragon_runs_dir()) {
  con <- store_open(runs_dir)
  policy_current(runs_dir)   # makes sure version 1 exists
  h <- store_get(con, "SELECT version, set_by, set_at FROM policies ORDER BY version DESC")
  ev <- store_get(con, "SELECT detail FROM events WHERE kind = 'policy_set'")
  notes <- lapply(ev$detail, function(d) jsonlite::fromJSON(d))
  why <- stats::setNames(vapply(notes, function(n) n$note %||% NA_character_, ""), vapply(notes, function(n) as.character(n$version %||% NA), ""))
  h$note <- unname(why[as.character(h$version)])
  h
}

# NULL when the agent may make the call now, else "NOT_ALLOWED" or
# "NEEDS_APPROVAL".
policy_check <- function(policy, agent, tool) {
  allowed <- unlist(policy$agents[[agent]]$tools)
  if (!tool$name %in% allowed) return("NOT_ALLOWED")
  if (tool$side_effect %in% unlist(policy$approvals$side_effects) || tool$name %in% unlist(policy$approvals$tools)) {
    return("NEEDS_APPROVAL")
  }
  NULL
}
