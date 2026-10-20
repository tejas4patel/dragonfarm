# Memory: what happened before, for agents to consult. Nothing is stored
# twice: past training runs are read back from their own config and status
# files, so the memory cannot drift from the runs themselves. The trainer
# agent uses it to pick settings that fit this machine first time ("the 3B
# at 1536 tokens without gradient checkpointing ran out of memory here").

training_outcomes <- function(model = NULL, limit = 20L, runs_dir = dragon_runs_dir()) {
  runs <- dragon_runs(runs_dir)
  if (!nrow(runs)) return(list())
  runs <- runs[order(runs$created_at, decreasing = TRUE), , drop = FALSE]
  if (!is.null(model)) runs <- runs[runs$model %in% model, , drop = FALSE]
  runs <- runs[!runs$state %in% c("queued", "running"), , drop = FALSE]
  lapply(utils::head(seq_len(nrow(runs)), limit), function(i) {
    d <- runs$dir[i]
    cfg <- tryCatch(read_json(file.path(d, "config.json")), error = function(e) list())
    st <- tryCatch(read_json(file.path(d, "status.json")), error = function(e) list())
    t <- cfg$train %||% list()
    minutes <- if (!is.null(st$started_at) && !is.null(st$finished_at)) {
      round(as.numeric(difftime(parse_iso(st$finished_at), parse_iso(st$started_at), units = "mins")), 1)
    }
    failed <- identical(st$state, "failed")
    list(run = runs$id[i], model = runs$model[i], stage = cfg$stage %||% "sft", state = st$state %||% "unknown",
         error_code = if (failed) st$error_code %||% legacy_error_code(st$error %||% "") else NULL,
         load_in_4bit = isTRUE(cfg$hardware$load_in_4bit), batch_size = t$per_device_batch_size,
         grad_accum = t$gradient_accumulation, max_seq_len = t$max_seq_len,
         gradient_checkpointing = isTRUE(t$gradient_checkpointing), device = st$device_name %||% st$device,
         minutes = minutes, eval_loss = st$eval_loss, trainer = st$backend %||% "transformers")
  })
}
