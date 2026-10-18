# An agent task's trace from the record: the task and every tool call it
# made, in order, with how long each took (model time is in the task's own
# entry). And the record as OpenTelemetry traces (OTLP JSON), so a company's
# observability stack can read it with no new dependency here.

task_trace <- function(task_id, runs_dir = dragon_runs_dir()) {
  ev <- store_get(store_open(runs_dir), "SELECT id, at, actor, kind, name, ok, code, detail, duration_ms FROM events ORDER BY id")
  if (!nrow(ev)) return(ev)
  tasks <- vapply(ev$detail, function(d) {
    if (is.na(d)) return(NA_character_)
    t <- tryCatch(jsonlite::fromJSON(d, simplifyVector = FALSE)$task, error = function(e) NULL)
    if (is.character(t) && length(t) == 1) t else NA_character_
  }, "", USE.NAMES = FALSE)
  ev[!is.na(tasks) & tasks == task_id, , drop = FALSE]
}

# Under an agent task in Activity: its steps as a small table.
agent_trace_view <- function(d, runs_dir = dragon_runs_dir()) {
  if (is.null(d$task)) return(NULL)
  tr <- task_trace(d$task, runs_dir)
  steps <- tr[tr$kind != "agent_run", , drop = FALSE]
  shiny::div(class = "trace-view",
    shiny::div(class = "kv", shiny::span("Goal"), shiny::strong(d$goal %||% "")),
    shiny::div(class = "kv", shiny::span("Model"), shiny::strong(d$model %||% "")),
    shiny::div(class = "kv", shiny::span("Model time"), shiny::strong(sprintf("%.1f s", (d$model_ms %||% 0) / 1000))),
    if (nrow(steps)) shiny::tags$table(class = "table table-sm",
      shiny::tags$thead(shiny::tags$tr(lapply(c("Step", "Tool", "Result", "Time"), shiny::tags$th))),
      shiny::tags$tbody(lapply(seq_len(nrow(steps)), function(i) shiny::tags$tr(
        shiny::tags$td(i), shiny::tags$td(steps$name[i]),
        shiny::tags$td(if (isTRUE(as.logical(steps$ok[i]))) "done" else steps$code[i] %||% "failed"),
        shiny::tags$td(if (is.na(steps$duration_ms[i])) "" else sprintf("%.1f s", steps$duration_ms[i] / 1000))
      ))))
    else shiny::p(class = "small", "No tool calls: the model answered directly.")
  )
}

otlp_nanos <- function(at) {
  t <- as.POSIXct(at, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  format(as.numeric(t) * 1e9, scientific = FALSE, trim = TRUE)
}

hex_id <- function(x, n) substr(rlang::hash(x), 1, n)

# Write the last `days` of the record as OTLP JSON traces: one trace per agent
# task (the task as the root span, its tool calls as children) and one span
# per other entry. Returns the file path. Times come from each entry's end
# time and duration.
store_export_otlp <- function(file, days = 7, runs_dir = dragon_runs_dir()) {
  since <- format(Sys.time() - days * 86400, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  ev <- store_get(store_open(runs_dir), "SELECT id, at, actor, kind, name, ok, code, detail, duration_ms FROM events WHERE at >= ? ORDER BY id",
                  params = list(since))
  details <- lapply(ev$detail, function(d) if (is.na(d)) list() else tryCatch(jsonlite::fromJSON(d, simplifyVector = FALSE), error = function(e) list()))
  task_of <- vapply(details, function(d) if (is.character(d$task) && length(d$task) == 1) d$task else NA_character_, "")
  roots <- stats::setNames(ev$id[ev$kind == "agent_run" & !is.na(task_of)], task_of[ev$kind == "agent_run" & !is.na(task_of)])
  spans <- lapply(seq_len(nrow(ev)), function(i) {
    end <- otlp_nanos(ev$at[i])
    dur <- if (is.na(ev$duration_ms[i])) 0 else ev$duration_ms[i]
    start <- format(as.numeric(end) - dur * 1e6, scientific = FALSE, trim = TRUE)
    task <- task_of[i]
    trace <- hex_id(if (!is.na(task)) task else paste("event", ev$id[i]), 32)
    parent <- if (!is.na(task) && ev$kind[i] != "agent_run" && !is.na(roots[task])) hex_id(paste("event", roots[[task]]), 16) else ""
    attrs <- list(list(key = "dragonfarm.kind", value = list(stringValue = ev$kind[i])),
                  list(key = "dragonfarm.event_id", value = list(intValue = as.character(ev$id[i]))),
                  list(key = "enduser.id", value = list(stringValue = ev$actor[i] %||% "")))
    if (!is.na(ev$code[i])) attrs <- c(attrs, list(list(key = "dragonfarm.code", value = list(stringValue = ev$code[i]))))
    list(traceId = trace, spanId = hex_id(paste("event", ev$id[i]), 16), parentSpanId = parent,
         name = paste(ev$kind[i], ev$name[i]), kind = 1L, startTimeUnixNano = start, endTimeUnixNano = end,
         attributes = attrs, status = list(code = if (isTRUE(as.logical(ev$ok[i]))) 1L else if (is.na(ev$ok[i])) 0L else 2L))
  })
  body <- list(resourceSpans = list(list(
    resource = list(attributes = list(list(key = "service.name", value = list(stringValue = "dragonfarm")))),
    scopeSpans = list(list(scope = list(name = "dragonfarm", version = as.character(utils::packageVersion("dragonfarm"))),
                           spans = spans)))))
  writeLines(as.character(jsonlite::toJSON(body, auto_unbox = TRUE, null = "null", digits = NA)), file, useBytes = TRUE)
  store_record_event("export", "otlp", ok = TRUE, detail = list(spans = length(spans), days = days), runs_dir = runs_dir)
  invisible(file)
}
