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
