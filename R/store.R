# The catalog: what exists (document sets and their versions, runs) and what
# happened (events). One SQLite file in the runs folder on a laptop; the same
# DBI code is meant to run against Postgres in a company. Big files
# (documents, chunks, embeddings, weights) stay in their folders; the catalog
# points at them and never changes them.
#
# Events are append-only: the database refuses updates and deletes, so the
# record of what was asked, run, approved, or refused cannot be edited.

store_schema_version <- 2L

store_ddl <- c(
  "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)",
  "CREATE TABLE IF NOT EXISTS document_sets (name TEXT PRIMARY KEY, dir TEXT NOT NULL, first_seen TEXT NOT NULL)",
  paste("CREATE TABLE IF NOT EXISTS set_versions (set_name TEXT NOT NULL, version INTEGER NOT NULL,",
        "chunks_md5 TEXT NOT NULL, reader_version INTEGER, n_sources INTEGER, n_chunks INTEGER,",
        "seen_at TEXT NOT NULL, PRIMARY KEY (set_name, version))"),
  paste("CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, dir TEXT NOT NULL, model TEXT, method TEXT,",
        "state TEXT, created_at TEXT, updated_at TEXT NOT NULL)"),
  paste("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL,",
        "actor TEXT, kind TEXT NOT NULL, name TEXT, ok INTEGER, code TEXT, detail TEXT, duration_ms INTEGER)"),
  "CREATE TABLE IF NOT EXISTS policies (version INTEGER PRIMARY KEY, body TEXT NOT NULL, set_by TEXT, set_at TEXT NOT NULL)",
  "CREATE TRIGGER IF NOT EXISTS policies_no_update BEFORE UPDATE ON policies BEGIN SELECT RAISE(ABORT, 'policy versions are append-only'); END",
  "CREATE TRIGGER IF NOT EXISTS policies_no_delete BEFORE DELETE ON policies BEGIN SELECT RAISE(ABORT, 'policy versions are append-only'); END",
  "CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT, 'events are append-only'); END",
  "CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'events are append-only'); END",
  # Model registry (schema 2): versions and sign-offs, both append-only.
  paste("CREATE TABLE IF NOT EXISTS model_versions (name TEXT NOT NULL, version INTEGER NOT NULL, run_id TEXT NOT NULL,",
        "run_dir TEXT, base_model TEXT, revision TEXT, data_md5 TEXT, evaluation TEXT, proposed_by TEXT,",
        "proposed_at TEXT NOT NULL, PRIMARY KEY (name, version))"),
  paste("CREATE TABLE IF NOT EXISTS model_signoffs (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,",
        "version INTEGER NOT NULL, decision TEXT NOT NULL CHECK (decision IN ('approved', 'rejected', 'retired')),",
        "meaning TEXT NOT NULL, signer TEXT, signed_at TEXT NOT NULL)"),
  "CREATE TRIGGER IF NOT EXISTS model_versions_no_update BEFORE UPDATE ON model_versions BEGIN SELECT RAISE(ABORT, 'model versions are append-only'); END",
  "CREATE TRIGGER IF NOT EXISTS model_versions_no_delete BEFORE DELETE ON model_versions BEGIN SELECT RAISE(ABORT, 'model versions are append-only'); END",
  "CREATE TRIGGER IF NOT EXISTS model_signoffs_no_update BEFORE UPDATE ON model_signoffs BEGIN SELECT RAISE(ABORT, 'sign-offs are append-only'); END",
  "CREATE TRIGGER IF NOT EXISTS model_signoffs_no_delete BEFORE DELETE ON model_signoffs BEGIN SELECT RAISE(ABORT, 'sign-offs are append-only'); END"
)

# Open (or create) the catalog for a runs folder; one connection per folder
# per session.
store_open <- function(runs_dir = dragon_runs_dir()) {
  # Create first, then normalise: a path that does not exist yet normalises
  # differently from the same path once it does (/var vs /private/var on
  # macOS, short 8.3 names on Windows), which would open a second connection.
  dir.create(runs_dir, recursive = TRUE, showWarnings = FALSE)
  runs_dir <- normalizePath(runs_dir, winslash = "/", mustWork = TRUE)
  if (is.null(the$stores)) the$stores <- list()
  con <- the$stores[[runs_dir]]
  if (!is.null(con) && DBI::dbIsValid(con)) return(con)
  con <- DBI::dbConnect(RSQLite::SQLite(), file.path(runs_dir, "dragonfarm.sqlite"))
  DBI::dbExecute(con, "PRAGMA busy_timeout = 5000")
  store_migrate(con)
  the$stores[[runs_dir]] <- con
  con
}

store_close_all <- function() {
  for (con in the$stores) if (DBI::dbIsValid(con)) DBI::dbDisconnect(con)
  the$stores <- list()
  invisible(NULL)
}

store_migrate <- function(con) {
  for (sql in store_ddl) DBI::dbExecute(con, sql)
  v <- DBI::dbGetQuery(con, "SELECT value FROM meta WHERE key = 'schema_version'")$value
  if (!length(v)) {
    DBI::dbExecute(con, "INSERT INTO meta (key, value) VALUES ('schema_version', ?)", params = list(as.character(store_schema_version)))
  } else if (as.integer(v) > store_schema_version) {
    cli::cli_abort("This runs folder's catalog was written by a newer dragonfarm (schema {v}); update the package.")
  } else if (as.integer(v) < store_schema_version) {
    # The tables above were just created; record the new schema.
    DBI::dbExecute(con, "UPDATE meta SET value = ? WHERE key = 'schema_version'", params = list(as.character(store_schema_version)))
  }
  invisible(con)
}

# Append one event. Never stops the work it records: a failed write returns
# FALSE with a warning.
store_record_event <- function(kind, name = NULL, ok = NA, code = NULL, detail = NULL, duration_ms = NULL,
                               runs_dir = dragon_runs_dir()) {
  tryCatch({
    con <- store_open(runs_dir)
    DBI::dbExecute(con, paste("INSERT INTO events (at, actor, kind, name, ok, code, detail, duration_ms)",
                              "VALUES (?, ?, ?, ?, ?, ?, ?, ?)"),
                   params = list(now_utc(), Sys.info()[["user"]] %||% NA_character_, kind, name %||% NA_character_,
                                 if (is.na(ok)) NA_integer_ else as.integer(ok), code %||% NA_character_,
                                 if (is.null(detail)) NA_character_ else as.character(jsonlite::toJSON(detail, auto_unbox = TRUE, null = "null")),
                                 if (is.null(duration_ms)) NA_integer_ else as.integer(duration_ms)))
    invisible(DBI::dbGetQuery(con, "SELECT last_insert_rowid() AS id")$id)
  }, error = function(e) {
    cli::cli_warn("Could not record an event in the catalog: {conditionMessage(e)}")
    invisible(NA_integer_)
  })
}

store_events <- function(limit = 100L, kind = NULL, runs_dir = dragon_runs_dir()) {
  con <- store_open(runs_dir)
  if (is.null(kind)) {
    DBI::dbGetQuery(con, "SELECT * FROM events ORDER BY id DESC LIMIT ?", params = list(as.integer(limit)))
  } else {
    DBI::dbGetQuery(con, "SELECT * FROM events WHERE kind = ? ORDER BY id DESC LIMIT ?", params = list(kind, as.integer(limit)))
  }
}

# Bring the catalog up to date with the folders: document sets get a new
# version whenever their chunks change (old versions are kept), runs are
# added or their state refreshed. Reads the folders; never writes to them.
store_sync <- function(runs_dir = dragon_runs_dir()) {
  con <- store_open(runs_dir)
  sets <- dragon_documents_list(runs_dir)
  new_versions <- 0L
  for (i in seq_len(nrow(sets))) {
    if (store_sync_set(con, sets$name[i], sets$dir[i])) new_versions <- new_versions + 1L
  }
  runs <- dragon_runs(runs_dir)
  for (i in seq_len(nrow(runs))) {
    DBI::dbExecute(con, paste("INSERT INTO runs (id, dir, model, method, state, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                              "ON CONFLICT(id) DO UPDATE SET state = excluded.state, updated_at = excluded.updated_at"),
                   params = list(runs$id[i], runs$dir[i], runs$model[i] %||% NA_character_, runs$method[i] %||% NA_character_,
                                 runs$state[i] %||% NA_character_, runs$created_at[i] %||% NA_character_, now_utc()))
  }
  invisible(list(sets = nrow(sets), new_versions = new_versions, runs = nrow(runs)))
}

store_sync_set <- function(con, name, dir) {
  chunks <- file.path(dir, "chunks.jsonl")
  if (!file.exists(chunks)) return(FALSE)
  md5 <- unname(tools::md5sum(chunks))
  DBI::dbExecute(con, "INSERT INTO document_sets (name, dir, first_seen) VALUES (?, ?, ?) ON CONFLICT(name) DO NOTHING",
                 params = list(name, normalizePath(dir, winslash = "/"), now_utc()))
  last <- DBI::dbGetQuery(con, "SELECT version, chunks_md5 FROM set_versions WHERE set_name = ? ORDER BY version DESC LIMIT 1",
                          params = list(name))
  if (nrow(last) && identical(last$chunks_md5[1], md5)) return(FALSE)
  m <- read_json(file.path(dir, "manifest.json"))
  DBI::dbExecute(con, paste("INSERT INTO set_versions (set_name, version, chunks_md5, reader_version, n_sources, n_chunks, seen_at)",
                            "VALUES (?, ?, ?, ?, ?, ?, ?)"),
                 params = list(name, if (nrow(last)) last$version[1] + 1L else 1L, md5,
                               as.integer(m$chunking$reader %||% NA_integer_), length(m$sources),
                               as.integer(m$n_chunks %||% NA_integer_), now_utc()))
  TRUE
}

now_utc <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
