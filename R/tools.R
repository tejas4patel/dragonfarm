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
    array = is.list(v) && is.null(names(v)) || (is.atomic(v) && length(v) != 1) || is.data.frame(v),
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
tool_call <- function(name, args = list()) {
  refuse <- function(error) {
    store_record_event("tool", name, ok = FALSE, code = "INVALID_ARGUMENTS", detail = list(args = args, error = error))
    list(ok = FALSE, code = "INVALID_ARGUMENTS", error = error)
  }
  args <- args %||% list()
  tool <- tool_registry()[[name]]
  if (is.null(tool)) return(refuse(sprintf("No tool called '%s'.", name)))
  problems <- schema_problems(args, tool$input)
  if (length(problems)) return(refuse(paste(problems, collapse = "; ")))
  args <- with_defaults(args, tool$input)
  t0 <- Sys.time()
  out <- tryCatch(
    list(ok = TRUE, result = tool_impl[[name]](args)),
    dragonfarm_not_a_set = function(e) list(ok = FALSE, code = "NOT_A_SET", error = conditionMessage(e)),
    dragonfarm_not_a_run = function(e) list(ok = FALSE, code = "NOT_A_RUN", error = conditionMessage(e)),
    dragonfarm_worker_error = function(e) list(ok = FALSE, code = e$code %||% "UNKNOWN", error = conditionMessage(e)),
    error = function(e) list(ok = FALSE, code = "UNKNOWN", error = conditionMessage(e))
  )
  # Every call is recorded: which tool, with what, whether it worked, how long.
  store_record_event("tool", name, ok = out$ok, code = out$code, detail = list(args = args),
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
    hits <- dragon_retrieve(docs, args$query, k = as.integer(args$k), method = args$method, extra = as.integer(args$extra))
    rows_as_list(hits, c("n", "id", "source", "section", "page", "text", "similarity"))
  },
  answer_question = function(args) {
    docs <- dragon_documents_load(args$set)
    model <- args$model
    if (!is.null(model) && !dir.exists(model) && dir.exists(file.path(dragon_runs_dir(), model))) model <- dragon_run(file.path(dragon_runs_dir(), model))
    a <- dragon_ask(docs, args$question, model = model, k = as.integer(args$k), compare = isTRUE(args$compare))
    list(answer = a$answer, model = a$model %||% "", sources = rows_as_list(a$sources, c("n", "source", "section", "page", "cited")))
  },
  list_runs = function(args) {
    runs <- dragon_runs()
    runs <- runs[order(runs$created_at, decreasing = TRUE), , drop = FALSE]
    rows_as_list(utils::head(runs, args$limit), c("id", "model", "state"))
  },
  run_status = function(args) {
    run <- run_from(args$run)
    st <- dragon_status(run)
    list(id = run$id, state = st$state %||% "unknown", total_steps = st$total_steps, eval_loss = st$eval_loss,
         error = if (!is.null(st$error)) error_message(st$error, st$error_code), error_code = st$error_code)
  }
)
