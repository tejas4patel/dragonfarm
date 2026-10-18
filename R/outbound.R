# Outbound gateway. Everything that sends data off this machine goes through
# outbound_check() first: the Claude API, fetching web pages as documents,
# publishing to Hugging Face, and a model server that is not on this machine.
# Each call is recorded (host, purpose, bytes sent), and an admin can limit
# the hosts in the policy (outbound.allowed_hosts), for example to none at
# all on a machine that must keep everything in. Calls to this machine
# itself (localhost) are not outbound.

outbound_host <- function(url) {
  tolower(sub("^[A-Za-z][A-Za-z0-9+.-]*://([^/@]*@)?(\\[[^]]*\\]|[^/:?#]+).*$", "\\2", url))
}

is_local_host <- function(host) {
  host %in% c("localhost", "127.0.0.1", "[::1]", "::1") || endsWith(host, ".localhost")
}

# "*" allows every host; "*.example.com" allows the subdomains of
# example.com and example.com itself.
host_allowed <- function(host, allowed) {
  for (a in allowed) {
    a <- tolower(a)
    if (identical(a, "*") || identical(a, host)) return(TRUE)
    if (startsWith(a, "*.") && (endsWith(host, substring(a, 2)) || identical(host, substring(a, 3)))) return(TRUE)
  }
  FALSE
}

# Check and record one outbound call. Raises NOT_ALLOWED when the policy
# does not list the host. `bytes` is roughly what is sent.
outbound_check <- function(url, purpose, bytes = NA_real_, runs_dir = dragon_runs_dir()) {
  host <- outbound_host(url)
  if (is_local_host(host)) return(invisible(TRUE))
  policy <- policy_current(runs_dir)
  allowed <- policy$outbound$allowed_hosts
  ok <- is.null(allowed) || host_allowed(host, unlist(allowed))
  store_record_event("outbound", host, ok = ok, code = if (!ok) "NOT_ALLOWED",
                     detail = list(purpose = purpose, bytes = bytes), runs_dir = runs_dir)
  if (!ok) {
    cli::cli_abort(c("The policy does not allow sending data to {.val {host}} ({purpose}).",
                     "i" = if (length(unlist(allowed))) "Allowed hosts: {paste(unlist(allowed), collapse = ', ')}." else "No outside hosts are allowed on this machine."),
                   class = "dragonfarm_error", code = "NOT_ALLOWED")
  }
  invisible(TRUE)
}
