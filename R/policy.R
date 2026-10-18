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
    return(c(body, list(version = 1L)))
  }
  c(jsonlite::fromJSON(row$body, simplifyVector = FALSE), list(version = as.integer(row$version)))
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
  bad <- setdiff(unlist(policy$approvals$side_effects), tool_side_effects)
  if (length(bad)) p <- c(p, sprintf("unknown side effect '%s'", bad))
  p
}

# Write a new policy version (an admin action; not a tool). Returns the version.
policy_set <- function(policy, set_by = Sys.info()[["user"]], runs_dir = dragon_runs_dir()) {
  policy$version <- NULL
  problems <- policy_problems(policy)
  if (length(problems)) cli::cli_abort(c("This policy has problems:", stats::setNames(problems, rep("x", length(problems)))))
  current <- policy_current(runs_dir)
  con <- store_open(runs_dir)
  v <- current$version + 1L
  store_exec(con, "INSERT INTO policies (version, body, set_by, set_at) VALUES (?, ?, ?, ?)",
                 params = list(v, as.character(jsonlite::toJSON(policy, auto_unbox = TRUE, null = "null")), set_by, now_utc()))
  store_record_event("policy_set", paste0("version ", v), ok = TRUE, detail = list(set_by = set_by), runs_dir = runs_dir)
  invisible(v)
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
