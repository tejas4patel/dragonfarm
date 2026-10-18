# Approvals inbox. An agent's call that the policy holds for a person is
# recorded as an "approval_request" (see tool_call()). A person approves or
# declines it; the decision is recorded as an "approval_decision" pointing at
# the request, and an approved call then runs as that person, on the agent's
# behalf. A declined call never runs, and a request is decided once.

approval_decisions <- function(runs_dir = dragon_runs_dir()) {
  ev <- DBI::dbGetQuery(store_open(runs_dir), "SELECT id, ok, actor, at, detail FROM events WHERE kind = 'approval_decision'")
  ev$of <- vapply(ev$detail, function(d) as.integer(jsonlite::fromJSON(d)$of %||% NA_integer_), 1L)
  ev
}

# Requests still waiting for a person, oldest first.
approvals_pending <- function(runs_dir = dragon_runs_dir()) {
  req <- DBI::dbGetQuery(store_open(runs_dir), "SELECT * FROM events WHERE kind = 'approval_request' ORDER BY id")
  req[!req$id %in% approval_decisions(runs_dir)$of, , drop = FALSE]
}

# Decide one request. Returns the tool's result when approved (list(ok, ...)
# as from tool_call()), or list(ok = TRUE, declined = TRUE).
approval_decide <- function(id, approve, note = NULL, runs_dir = dragon_runs_dir()) {
  ev <- store_event(id, runs_dir)
  if (!identical(ev$kind, "approval_request")) {
    cli::cli_abort("Event {id} is not a request for approval.", class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  if (as.integer(id) %in% approval_decisions(runs_dir)$of) {
    cli::cli_abort("Request {id} has already been decided.", class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  }
  agent <- ev$detail$agent
  store_record_event("approval_decision", ev$name, ok = isTRUE(approve),
                     detail = list(of = as.integer(id), agent = agent, note = note), runs_dir = runs_dir)
  if (!isTRUE(approve)) return(list(ok = TRUE, declined = TRUE))
  tool_call(ev$name, ev$detail$args %||% list(), on_behalf_of = list(agent = agent, approval = as.integer(id)))
}

# One line per pending request, for the inbox.
approvals_table <- function(pending) {
  if (!nrow(pending)) return(data.frame(Note = "Nothing is waiting for you."))
  details <- lapply(pending$detail, function(d) jsonlite::fromJSON(d, simplifyVector = FALSE))
  data.frame(
    Request = pending$id,
    When = sub("T", " ", sub("Z$", "", pending$at)),
    Agent = vapply(details, function(d) d$agent %||% "", ""),
    Wants = pending$name,
    With = vapply(details, function(d) {
      a <- d$args %||% list()
      if (!length(a)) return("")
      s <- paste(sprintf("%s = %s", names(a), vapply(a, function(v) paste(format(unlist(v)), collapse = ", "), "")), collapse = "; ")
      if (nchar(s) > 120) paste0(substr(s, 1, 120), " ...") else s
    }, ""),
    check.names = FALSE
  )
}
