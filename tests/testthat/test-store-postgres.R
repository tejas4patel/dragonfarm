# The catalog on Postgres (a company's shared catalog). Runs only when
# DRAGONFARM_TEST_PG holds a postgresql:// address; each test gets an empty
# schema of its own.
pg_catalog <- function(env = parent.frame()) {
  uri <- Sys.getenv("DRAGONFARM_TEST_PG")
  testthat::skip_if(!nzchar(uri), "set DRAGONFARM_TEST_PG to a postgresql:// address")
  testthat::skip_if_not_installed("RPostgres")
  # timezone = NULL: portable test servers may ship without time-zone data.
  con <- do.call(DBI::dbConnect, c(list(RPostgres::Postgres(), bigint = "integer", timezone = NULL), dragonfarm:::pg_uri_parts(uri)))
  schema <- paste0("t_", paste(sample(letters, 10, TRUE), collapse = ""))
  DBI::dbExecute(con, sprintf("CREATE SCHEMA %s", schema))
  DBI::dbExecute(con, sprintf("SET search_path TO %s", schema))
  dragonfarm:::store_close_all()
  withr::local_options(dragonfarm.catalog = function() con, dragonfarm.runs_dir = withr::local_tempdir(.local_envir = env),
                       .local_envir = env)
  withr::defer({
    dragonfarm:::store_close_all()
    con2 <- do.call(DBI::dbConnect, c(list(RPostgres::Postgres(), timezone = NULL), dragonfarm:::pg_uri_parts(uri)))
    DBI::dbExecute(con2, sprintf("DROP SCHEMA %s CASCADE", schema))
    DBI::dbDisconnect(con2)
  }, envir = env)
  con
}

test_that("on Postgres, the schema is created and events are append-only", {
  con <- pg_catalog()
  id1 <- dragonfarm:::store_record_event("tool", "search_documents", ok = TRUE, detail = list(args = list(query = "q")))
  id2 <- dragonfarm:::store_record_event("tool", "list_runs", ok = FALSE, code = "NOT_ALLOWED")
  expect_equal(c(id1, id2), 1:2)
  ev <- dragonfarm:::store_events(5)
  expect_equal(ev$name, c("list_runs", "search_documents"))
  expect_equal(jsonlite::fromJSON(ev$detail[2])$args$query, "q")
  expect_error(DBI::dbExecute(con, "UPDATE events SET ok = 0"), "append-only")
  expect_error(DBI::dbExecute(con, "DELETE FROM events"), "append-only")
  expect_equal(DBI::dbGetQuery(con, "SELECT value FROM meta WHERE key = 'schema_version'")$value,
               as.character(dragonfarm:::store_schema_version))
})

test_that("on Postgres, policies, approvals and the model registry work as on SQLite", {
  con <- pg_catalog()
  runs <- getOption("dragonfarm.runs_dir")
  pol <- dragonfarm:::policy_default()
  pol$approvals$tools <- c(unlist(pol$approvals$tools), "list_runs")
  expect_equal(dragonfarm:::policy_set(pol, set_by = "admin"), 2L)
  expect_null(dragonfarm:::policy_current()$outbound$allowed_hosts)
  expect_error(DBI::dbExecute(con, "DELETE FROM policies"), "append-only")

  expect_equal(tool_call("list_runs", list(limit = 2), agent = "ops")$code, "NEEDS_APPROVAL")
  p <- dragonfarm:::approvals_pending()
  expect_equal(nrow(p), 1)
  expect_true(dragonfarm:::approval_decide(p$id, approve = TRUE)$ok)
  expect_equal(nrow(dragonfarm:::approvals_pending()), 0)

  d <- file.path(runs, "run-1"); dir.create(file.path(d, "data"), recursive = TRUE)
  jsonlite::write_json(list(model = list(id = "m"), data = list(train = "data/train.jsonl")), file.path(d, "config.json"), auto_unbox = TRUE)
  jsonlite::write_json(list(state = "succeeded", eval_loss = 1), file.path(d, "status.json"), auto_unbox = TRUE)
  writeLines("{}", file.path(d, "data", "train.jsonl"))
  expect_equal(dragonfarm:::registry_propose(d, "bot")$version, 1L)
  dragonfarm:::registry_sign_off("bot", 1, "approved", meaning = "For support", signer = "ana")
  expect_equal(dragonfarm:::registry_approved("bot")$signer, "ana")
  expect_error(DBI::dbExecute(con, "UPDATE model_signoffs SET meaning = 'x'"), "append-only")
})

test_that("on Postgres, free-tier counts and set versions work", {
  pg_catalog()
  dragonfarm:::provider_opt_in("groq", daily_cap = 3)
  for (i in 1:2) dragonfarm:::store_record_event("outbound", "api.groq.com", ok = TRUE, detail = list(purpose = "free tier: groq"))
  st <- dragonfarm:::provider_status("groq")
  expect_true(st$opted_in); expect_equal(st$daily_cap, 3); expect_equal(st$used_today, 2L)
  f <- write_fake_set()
  con <- dragonfarm:::store_open()
  expect_true(dragonfarm:::store_sync_set(con, "kb", f$dir))
  expect_false(dragonfarm:::store_sync_set(con, "kb", f$dir))      # same chunks: no new version
  expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM set_versions")$n, 1L)
})

test_that("postgresql:// addresses are read into connection arguments", {
  p <- dragonfarm:::pg_uri_parts("postgresql://ana:s%40cret@db.example.com:6543/catalog")
  expect_equal(p, list(user = "ana", password = "s@cret", host = "db.example.com", port = "6543", dbname = "catalog"))
  expect_equal(dragonfarm:::pg_uri_parts("postgresql://postgres:@127.0.0.1:6425/postgres"),
               list(user = "postgres", host = "127.0.0.1", port = "6425", dbname = "postgres"))
  expect_error(dragonfarm:::pg_uri_parts("mysql://x"), class = "dragonfarm_error")
})

test_that("on Postgres, identity, governed mode, access rules, fallbacks and the 7-day summary work", {
  pg_catalog()
  runs <- getOption("dragonfarm.runs_dir")
  withr::local_options(dragonfarm.user = "jo.lee")
  pol <- dragonfarm:::policy_default()
  pol$registry$governed <- TRUE
  pol$admins <- list("jo.lee")
  pol$access <- list(list(set = "kb", documents = "policy*.pdf", groups = list("hr")))
  expect_equal(dragonfarm:::policy_set(pol), 2L)
  expect_equal(dragonfarm:::policy_history()$set_by[1], "jo.lee")
  got <- dragonfarm:::policy_current()
  expect_true(got$registry$governed)
  expect_true(dragonfarm:::policy_admin(list(user = "jo.lee"), got))
  expect_false(dragonfarm:::policy_admin(list(user = "sam.k"), got))
  expect_equal(dragonfarm:::access_hidden("kb", c("policy.pdf", "NEWS.md"), policy = got), "policy.pdf")
  err <- tryCatch(dragonfarm:::serving_check(list(model = "m", adapter = file.path(runs, "run-x", "adapter"))), dragonfarm_error = function(e) e$code)
  expect_equal(err, "NOT_APPROVED")
  dragonfarm:::store_record_event("agent_run", "answer", ok = FALSE, code = "BUDGET_EXHAUSTED")
  dragonfarm:::store_record_event("fallback", "answer", ok = TRUE, code = "BUDGET_EXHAUSTED")
  sm <- dragonfarm:::store_summary(7)
  expect_equal(sm$agents$fell_back, 1)
  expect_equal(dragonfarm:::store_events(1)$actor, "jo.lee")
})

test_that("an app role that only reads and appends works and cannot remove the protection (D-37)", {
  con <- pg_catalog()
  schema <- DBI::dbGetQuery(con, "SELECT current_schema() AS s")$s
  tag <- paste(sample(letters, 8, TRUE), collapse = "")
  owner <- paste0("df_owner_", tag); app <- paste0("df_app_", tag)
  DBI::dbExecute(con, sprintf("CREATE ROLE %s NOLOGIN", owner))
  DBI::dbExecute(con, sprintf("CREATE ROLE %s NOLOGIN", app))
  withr::defer({
    DBI::dbExecute(con, "RESET ROLE")
    DBI::dbExecute(con, sprintf("DROP SCHEMA IF EXISTS %s CASCADE", schema))
    DBI::dbExecute(con, sprintf("CREATE SCHEMA %s", schema))   # the fixture drops it again
    DBI::dbExecute(con, sprintf("DROP OWNED BY %s, %s", owner, app))
    DBI::dbExecute(con, sprintf("DROP ROLE %s", app)); DBI::dbExecute(con, sprintf("DROP ROLE %s", owner))
  })
  DBI::dbExecute(con, sprintf("ALTER SCHEMA %s OWNER TO %s", schema, owner))
  # The owner sets the catalogue up once.
  DBI::dbExecute(con, sprintf("SET ROLE %s", owner))
  dragonfarm:::store_migrate(con)
  expect_true(dragonfarm:::store_pg_current(con))
  for (g in c(sprintf("GRANT USAGE ON SCHEMA %s TO %s", schema, app),
              sprintf("GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA %s TO %s", schema, app),
              sprintf("GRANT UPDATE ON %s.runs TO %s", schema, app),
              sprintf("GRANT USAGE ON ALL SEQUENCES IN SCHEMA %s TO %s", schema, app))) DBI::dbExecute(con, g)
  # The app connects with the restricted role.
  DBI::dbExecute(con, "RESET ROLE"); DBI::dbExecute(con, sprintf("SET ROLE %s", app))
  expect_silent(dragonfarm:::store_migrate(con))                      # nothing to set up, nothing attempted
  expect_true(is.numeric(dragonfarm:::store_record_event("tool", "list_runs", ok = TRUE)))
  refused <- function(sql) inherits(tryCatch(DBI::dbExecute(con, sql), error = function(e) e), "error")
  expect_true(refused("UPDATE events SET ok = 0"))
  expect_true(refused("ALTER TABLE events DISABLE TRIGGER ALL"))
  expect_true(refused("DROP TRIGGER events_append_only ON events"))
  expect_true(refused("DELETE FROM events"))
})
