# An in-memory keychain, so tests never touch the real one.
fake_keychain <- function(env = parent.frame()) {
  store <- new.env()
  testthat::local_mocked_bindings(
    keychain_available = function() TRUE,
    keychain_get = function(var) store[[var]],
    keychain_set = function(var, value) assign(var, value, envir = store),
    keychain_delete = function(var) if (exists(var, envir = store, inherits = FALSE)) rm(list = var, envir = store),
    .env = env
  )
  store
}

clean_env <- function(env = parent.frame()) {
  vars <- unlist(lapply(dragonfarm:::secret_catalog(), `[[`, "vars"))
  withr::local_envvar(stats::setNames(rep("", length(vars)), vars), .local_envir = env)
  withr::local_options(dragonfarm.runs_dir = withr::local_tempdir(.local_envir = env), .local_envir = env)
}
