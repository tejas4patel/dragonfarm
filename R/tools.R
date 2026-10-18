# Tools: the package's capabilities behind typed contracts, for agents.
#
# Each tool is described by a JSON file in inst/tools/ (name, purpose,
# side-effect class, cost hints, error codes, and JSON Schemas for its input
# and output). Agents and outside clients see only these contracts; the
# implementations below are thin wrappers over the dragon_*() functions.
# Internal until the agent runtime exists, so nothing here is public API yet.

tool_side_effects <- c("read_only", "writes", "irreversible", "outbound")

tool_registry <- function(refresh = FALSE) {
  if (!refresh && !is.null(the$tools)) return(the$tools)
  dir <- system.file("tools", package = "dragonfarm")
  files <- list.files(dir, pattern = "[.]json$", full.names = TRUE)
  files <- files[basename(files) != "error_codes.json"]
  tools <- lapply(files, function(f) jsonlite::fromJSON(f, simplifyVector = FALSE))
  names(tools) <- vapply(tools, function(t) t$name %||% "", "")
  the$tools <- tools
  tools
}

tool_error_codes <- function() {
  names(jsonlite::fromJSON(system.file("tools", "error_codes.json", package = "dragonfarm"), simplifyVector = FALSE))
}

# Problems with a tool contract itself (empty when it is well formed).
tool_contract_problems <- function(tool, file_name = NULL) {
  p <- character()
  for (field in c("name", "title", "description", "side_effect", "cost", "errors", "input", "output")) {
    if (is.null(tool[[field]])) p <- c(p, sprintf("missing '%s'", field))
  }
  if (length(p)) return(p)
  if (!is.null(file_name) && !identical(paste0(tool$name, ".json"), file_name)) p <- c(p, "file name does not match the tool name")
  if (!tool$side_effect %in% tool_side_effects) p <- c(p, sprintf("unknown side effect '%s'", tool$side_effect))
  if (!identical(tool$input$type, "object")) p <- c(p, "input must be an object schema")
  unknown <- setdiff(unlist(tool$errors), tool_error_codes())
  if (length(unknown)) p <- c(p, sprintf("unknown error code '%s'", unknown))
  if (!is.function(tool_impl[[tool$name]])) p <- c(p, "no implementation")
  p
}

# Check a value against the subset of JSON Schema the contracts use (type,
# required, additionalProperties, properties, items, enum, minimum, maximum,
# minLength). Returns the problems found, each naming where.
schema_problems <- function(value, schema, path = "input") {
  type_ok <- function(v, t) switch(t,
    string = is.character(v) && length(v) == 1 && !is.na(v),
    integer = is.numeric(v) && length(v) == 1 && !is.na(v) && v == round(v),
    number = is.numeric(v) && length(v) == 1 && !is.na(v),
    boolean = is.logical(v) && length(v) == 1 && !is.na(v),
    null = is.null(v),
    array = (is.list(v) && is.null(names(v))) || (is.atomic(v) && !is.null(v)) || is.data.frame(v),
    object = is.list(v) && (!is.null(names(v)) || length(v) == 0) && !is.data.frame(v),
    FALSE)
  types <- unlist(schema$type)
  if (length(types) && !any(vapply(types, function(t) type_ok(value, t), TRUE))) {
    return(sprintf("%s must be %s", path, paste(types, collapse = " or ")))
  }
  if (is.null(value)) return(character())
  p <- character()
  if (!is.null(schema$enum) && !(value %in% unlist(schema$enum))) {
    p <- c(p, sprintf("%s must be one of %s", path, paste(unlist(schema$enum), collapse = ", ")))
  }
  if (is.numeric(value) && length(value) == 1) {
    if (!is.null(schema$minimum) && value < schema$minimum) p <- c(p, sprintf("%s must be at least %s", path, schema$minimum))
    if (!is.null(schema$maximum) && value > schema$maximum) p <- c(p, sprintf("%s must be at most %s", path, schema$maximum))
  }
  if (is.character(value) && length(value) == 1 && !is.null(schema$minLength) && nchar(value) < schema$minLength) {
    p <- c(p, sprintf("%s must not be empty", path))
  }
  if ("object" %in% types && is.list(value) && !is.data.frame(value)) {
    for (r in unlist(schema$required)) if (is.null(value[[r]])) p <- c(p, sprintf("%s.%s is required", path, r))
    if (isFALSE(schema$additionalProperties)) {
      extra <- setdiff(names(value), names(schema$properties))
      if (length(extra)) p <- c(p, sprintf("%s.%s is not allowed", path, extra))
    }
    for (nm in intersect(names(value), names(schema$properties))) {
      p <- c(p, schema_problems(value[[nm]], schema$properties[[nm]], paste0(path, ".", nm)))
    }
  }
  if ("array" %in% types && !is.null(schema$items)) {
    items <- if (is.data.frame(value)) lapply(seq_len(nrow(value)), function(i) as.list(value[i, , drop = FALSE])) else value
    for (i in seq_along(items)) p <- c(p, schema_problems(items[[i]], schema$items, sprintf("%s[%d]", path, i)))
  }
  p
}

# Defaults from the schema for arguments not given.
with_defaults <- function(args, schema) {
  for (nm in names(schema$properties)) {
    d <- schema$properties[[nm]]
    if (is.null(args[[nm]]) && "default" %in% names(d) && !is.null(d$default)) args[[nm]] <- d$default
  }
  args
}

# Call a tool by name. Never throws: returns list(ok = TRUE, result = ...) or
# list(ok = FALSE, code = "<CODE>", error = "<message>").
# `agent` names the agent making the call; NULL means a person acting
# directly, which needs no approval. An agent's call is checked against the
# current policy: refused (NOT_ALLOWED), or held for a person (NEEDS_APPROVAL,
# recorded as an approval request). `on_behalf_of` is set when a person runs
# a call an agent asked for, after approving it (approval_decide()); it is
# recorded with the call.
tool_call <- function(name, args = list(), agent = NULL, on_behalf_of = NULL) {
  refuse <- function(code, error, kind = "tool") {
    store_record_event(kind, name, ok = FALSE, code = code, detail = list(agent = agent, args = args, error = error))
    list(ok = FALSE, code = code, error = error)
  }
  args <- args %||% list()
  tool <- tool_registry()[[name]]
  if (is.null(tool)) return(refuse("INVALID_ARGUMENTS", sprintf("No tool called '%s'.", name)))
  problems <- schema_problems(args, tool$input)
  if (length(problems)) return(refuse("INVALID_ARGUMENTS", paste(problems, collapse = "; ")))
  if (!is.null(agent)) {
    policy <- policy_current()
    verdict <- policy_check(policy, agent, tool)
    if (identical(verdict, "NOT_ALLOWED")) {
      return(refuse("NOT_ALLOWED", sprintf("Policy version %d does not let agent '%s' call '%s'.", policy$version, agent, name)))
    }
    if (identical(verdict, "NEEDS_APPROVAL")) {
      return(refuse("NEEDS_APPROVAL", sprintf("Policy version %d says a person must approve '%s' first.", policy$version, name),
                    kind = "approval_request"))
    }
  }
  args <- with_defaults(args, tool$input)
  t0 <- Sys.time()
  out <- tryCatch(
    list(ok = TRUE, result = tool_impl[[name]](args)),
    # The package's own errors carry a code (see inst/tools/error_codes.json).
    dragonfarm_error = function(e) list(ok = FALSE, code = e$code %||% "UNKNOWN", error = conditionMessage(e)),
    error = function(e) list(ok = FALSE, code = "UNKNOWN", error = conditionMessage(e))
  )
  # Every call is recorded: which tool, with what, whether it worked, how long.
  # A successful call also records a fingerprint of its result and what it
  # depended on, so it can be replayed and compared (tool_replay()).
  detail <- list(agent = agent, args = args)
  if (!is.null(on_behalf_of)) detail$on_behalf_of <- on_behalf_of
  if (isTRUE(out$ok)) {
    detail$result_hash <- result_hash(out$result)
    detail$result_preview <- result_preview(out$result)
    detail$context <- tool_context(args, out$result)
  }
  store_record_event("tool", name, ok = out$ok, code = out$code, detail = detail,
                     duration_ms = round(1000 * as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  out
}

rows_as_list <- function(df, cols) {
  cols <- intersect(cols, names(df))
  lapply(seq_len(nrow(df)), function(i) {
    row <- lapply(cols, function(cl) {
      v <- df[[cl]][[i]]
      if (length(v) == 1 && is.na(v)) NULL else v
    })
    names(row) <- cols
    row
  })
}

run_from <- function(run) {
  if (!dir.exists(run) && dir.exists(file.path(dragon_runs_dir(), run))) run <- file.path(dragon_runs_dir(), run)
  dragon_run(run)
}

tool_impl <- list(
  list_document_sets = function(args) {
    sets <- dragon_documents_list()
    lapply(seq_len(nrow(sets)), function(i) list(name = sets$name[i], n_sources = as.integer(sets$sources[i]),
                                                 n_chunks = as.integer(sets$chunks[i]), indexed = isTRUE(sets$indexed[i])))
  },
  search_documents = function(args) {
    docs <- dragon_documents_load(args$set)
    if (!is.null(args$source)) {
      # One document: rank the whole set, keep that document's top k.
      ch <- dragon_chunks(docs)
      want <- unique(ch$source[tolower(ch$source) == tolower(args$source)])
      if (!length(want)) {
        cli::cli_abort(c("No document called {.val {args$source}} in this set.", i = "It has: {.val {sort(unique(ch$source))}}."),
                       class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
      }
      hits <- dragon_retrieve(docs, args$query, k = nrow(ch), method = args$method)
      hits <- utils::head(hits[hits$source == want, , drop = FALSE], as.integer(args$k))
      hits$n <- seq_len(nrow(hits))
    } else {
      hits <- dragon_retrieve(docs, args$query, k = as.integer(args$k), method = args$method, extra = as.integer(args$extra))
    }
    rows_as_list(hits, c("n", "id", "source", "section", "page", "text", "similarity"))
  },
  answer_question = function(args) {
    docs <- dragon_documents_load(args$set)
    model <- args$model
    if (!is.null(model) && !dir.exists(model) && dir.exists(file.path(dragon_runs_dir(), model))) model <- dragon_run(file.path(dragon_runs_dir(), model))
    a <- dragon_ask(docs, args$question, model = model, k = as.integer(args$k), compare = isTRUE(args$compare))
    list(answer = a$answer, model = a$model %||% "", sources = rows_as_list(a$sources, c("n", "id", "source", "section", "page", "cited")))
  },
  list_runs = function(args) {
    runs <- dragon_runs()
    runs <- runs[order(runs$created_at, decreasing = TRUE), , drop = FALSE]
    rows_as_list(utils::head(runs, args$limit), c("id", "model", "state"))
  },
  read_documents = function(args) {
    docs <- suppressWarnings(dragon_documents(unlist(args$paths), name = args$name, index = TRUE))
    con <- store_open()
    version <- store_get(con, "SELECT MAX(version) v FROM set_versions WHERE set_name = ?", params = list(docs$name))$v
    failed <- Filter(function(src) !is.null(src$error), docs$manifest$sources)
    list(name = docs$name, n_sources = length(docs$manifest$sources), n_chunks = as.integer(docs$manifest$n_chunks %||% 0L),
         version = as.integer(version), failed = lapply(failed, function(src) list(name = src$name, error = src$error)))
  },
  write_practice_questions = function(args) {
    docs <- dragon_documents_load(args$set)
    qa <- dragon_questions(docs, generator = args$model, n_per_chunk = as.integer(args$n_per_chunk), mix = isTRUE(args$mix), wait = TRUE)
    list(questions = attr(qa, "path"), n_pairs = nrow(qa), n_kept = sum(qa$keep))
  },
  train_model = function(args) {
    qa <- dragon_questions_load(args$questions)
    ds <- dragon_questions_dataset(qa)
    hw <- tryCatch(hardware_info(), error = function(e) NULL)
    four_bit <- isTRUE(suggest_train_4bit(args$model, hw))
    # A model that needs 4-bit on this GPU also needs batch 1 and gradient
    # checkpointing to fit (measured: a 3B without checkpointing ran out of 8 GB).
    targs <- if (four_bit) dragon_train_args(epochs = args$epochs, batch_size = 1, grad_accum = 16, gradient_checkpointing = TRUE, max_seq_len = 1536)
             else dragon_train_args(epochs = args$epochs)
    run <- dragon_train(ds, args$model, args = targs, hardware = dragon_hardware(load_in_4bit = four_bit), name = args$name, wait = FALSE)
    list(run = run$id, state = dragon_status(run)$state %||% "queued", load_in_4bit = four_bit)
  },
  evaluate_run = function(args) {
    run <- run_from(args$run)
    e <- dragon_evaluate(run)
    list(run = run$id, eval_loss = e$eval_loss, perplexity = e$perplexity, pref_accuracy = e$pref_accuracy,
         n_samples = if (is.data.frame(e$samples)) nrow(e$samples) else 0L)
  },
  scan_personal_data = function(args) {
    docs <- dragon_documents_load(args$set)
    h <- pii_scan(docs)
    list(set = docs$name, counts = as.list(attr(h, "counts")),
         hits = rows_as_list(utils::head(h, 50), c("type", "match", "source", "chunk")))
  },
  check_answer = function(args) {
    docs <- dragon_documents_load(args$set)
    ch <- dragon_chunks(docs)
    src <- data.frame(n = vapply(args$sources, function(x) as.integer(x$n), 0L), id = vapply(args$sources, function(x) as.character(x$id), ""))
    src$text <- ch$text[match(src$id, ch$id)]
    src$text[is.na(src$text)] <- ""
    r <- answer_check(args$answer, src, args$question %||% "")
    r[c("citations", "bad_citations")] <- lapply(r[c("citations", "bad_citations")], as.list)
    r[c("figures", "ungrounded")] <- lapply(r[c("figures", "ungrounded")], function(x) as.list(unname(x)))
    r
  },
  verify_document_set = function(args) {
    v <- documents_verify(args$set)
    v[c("set", "verdict", "files", "missing", "changed", "not_checked", "reader_then", "reader_now", "chunks_differ")]
  },
  recall_training = function(args) {
    training_outcomes(model = args$model, limit = as.integer(args$limit))
  },
  promote_model = function(args) {
    registry_propose(run_from(args$run), args$name)
  },
  cancel_run = function(args) {
    run <- run_from(args$run)
    if (dragon_status(run)$state %in% c("queued", "running")) dragon_cancel(run)
    list(run = run$id, state = dragon_status(run)$state %||% "unknown")
  },
  run_status = function(args) {
    run <- run_from(args$run)
    st <- dragon_status(run)
    list(id = run$id, state = st$state %||% "unknown", total_steps = st$total_steps, eval_loss = st$eval_loss,
         error = if (!is.null(st$error)) error_message(st$error, st$error_code), error_code = st$error_code)
  }
)
