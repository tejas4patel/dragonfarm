# Who is acting. In the app on Posit Connect (or any Shiny server that signs
# people in), the session knows the signed-in user and their groups; on a
# laptop it is the operating-system user. Every entry in the record, every
# proposal, sign-off and policy change names this person.
current_user <- function(session = shiny::getDefaultReactiveDomain()) {
  u <- tryCatch(session$user, error = function(e) NULL)
  if (is.character(u) && length(u) == 1 && nzchar(u)) return(u)
  u <- getOption("dragonfarm.user")
  if (is.character(u) && length(u) == 1 && nzchar(u)) return(u)
  Sys.info()[["user"]] %||% NA_character_
}

current_groups <- function(session = shiny::getDefaultReactiveDomain()) {
  g <- tryCatch(session$groups, error = function(e) NULL)
  if (is.character(g)) g else character()
}

# Who may change the policy. When the policy names admins (people) or admin
# groups (as the sign-in service reports them), only they may; otherwise the
# dragonfarm.admin option decides, as on a laptop (everyone, unless set FALSE).
policy_admin <- function(session = shiny::getDefaultReactiveDomain(), policy = NULL) {
  policy <- policy %||% tryCatch(policy_current(), error = function(e) NULL)
  people <- unlist(policy$admins)
  groups <- unlist(policy$admin_groups)
  if (length(people) || length(groups)) {
    return(isTRUE(current_user(session) %in% people) || any(current_groups(session) %in% groups))
  }
  !isFALSE(getOption("dragonfarm.admin"))
}

# Document-level access (policy$access): rules of the form
#   {"set": "sops", "documents": "hr-*.pdf", "groups": ["hr"]}
# A document a rule matches is seen only by members of the rule's groups
# (or the people it names in "users"); documents no rule matches are open to
# everyone who can open the set. Returns the set's documents this person may
# not see, or character() when nothing is hidden.
access_hidden <- function(set, sources, policy = NULL, session = shiny::getDefaultReactiveDomain()) {
  rules <- (policy %||% tryCatch(policy_current(), error = function(e) NULL))$access
  if (!length(rules)) return(character())
  user <- current_user(session)
  groups <- current_groups(session)
  sources <- unique(sources)
  hidden <- character()
  for (src in sources) {
    matching <- Filter(function(r) identical(r$set %||% set, set) && grepl(utils::glob2rx(r$documents %||% "*"), src), rules)
    if (!length(matching)) next
    allowed <- any(vapply(matching, function(r) user %in% unlist(r$users) || any(groups %in% unlist(r$groups)), TRUE))
    if (!allowed) hidden <- c(hidden, src)
  }
  hidden
}
