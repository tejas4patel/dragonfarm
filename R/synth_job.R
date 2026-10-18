# "Let a stronger model write the replies" in the app (D-16): the mapped
# prompts go to a teacher in a background R process, and the replies come
# back as a new prompt-and-response set to review and train on. The teacher
# is the best local model by default; Claude or a free tier only when a
# person picks one, and every request still passes the outbound check. The
# saved job names the teacher; it never holds a key.

synth_teacher <- function(spec, system = NULL, runs_dir = dragon_runs_dir()) {
  switch(spec$kind,
    local = spec$model,
    anthropic = dragon_llm_anthropic(model = spec$model %||% "claude-sonnet-5", system = system),
    provider = llm_provider(spec$provider, spec$model, system = system, runs_dir = runs_dir),
    cli::cli_abort("Unknown teacher {.val {spec$kind}}.", class = "dragonfarm_error", code = "INVALID_ARGUMENTS")
  )
}

synth_jobs_dir <- function(runs_dir = dragon_runs_dir()) file.path(runs_dir, "jobs")

# Start the job; returns list(id, status, log).
synth_job_start <- function(prompts, teacher, system = NULL, runs_dir = dragon_runs_dir()) {
  dir.create(synth_jobs_dir(runs_dir), recursive = TRUE, showWarnings = FALSE)
  id <- sprintf("synth-%s-%s", format(Sys.time(), "%Y%m%d-%H%M%S"), paste(sample(c(letters, 0:9), 4, TRUE), collapse = ""))
  base <- file.path(synth_jobs_dir(runs_dir), id)
  spec <- list(prompts = prompts, teacher = teacher, system = system, runs_dir = runs_dir, status = paste0(base, ".json"))
  saveRDS(spec, paste0(base, ".rds"))
  write_json(list(state = "queued", teacher = teacher, n_prompts = length(prompts)), spec$status)
  if (!identical(teacher$kind, "local")) {
    store_record_event("approval_decision", "synthesize_with_outside_teacher", ok = TRUE,
                       detail = list(teacher = teacher, n_prompts = length(prompts)), runs_dir = runs_dir)
  }
  script <- paste0(base, ".R")
  writeLines(sprintf("%s; dragonfarm:::synth_job_run('%s')", package_loader(), normalizePath(paste0(base, ".rds"), winslash = "/", mustWork = FALSE)), script)
  launch_rscript(script, paste0(base, ".log"))
  list(id = id, status = spec$status, log = paste0(base, ".log"))
}

synth_job_run <- function(spec_path) {
  spec <- readRDS(spec_path)
  options(dragonfarm.runs_dir = spec$runs_dir)
  write_json(list(state = "running", teacher = spec$teacher, n_prompts = length(spec$prompts), pid = Sys.getpid()), spec$status)
  res <- tryCatch({
    if (identical(spec$teacher$kind, "local")) require_gpu_free("Writing replies with a local model")
    ds <- dragon_synthesize(spec$prompts, synth_teacher(spec$teacher, spec$system, spec$runs_dir), system = spec$system,
                            runs_dir = spec$runs_dir, name = "app")
    meta <- attr(ds, "synthesis")
    list(state = "succeeded", file = ds$source, n_kept = nrow(ds$data), n_prompts = length(spec$prompts),
         dropped = sum(unlist(meta$dropped)), teacher = meta$teacher)
  }, error = function(e) list(state = "failed", error = conditionMessage(e), code = e$code %||% NULL))
  write_json(res, spec$status)
  invisible(res)
}

synth_job_status <- function(status_path) {
  if (!file.exists(status_path)) return(list(state = "queued"))
  tryCatch(read_json(status_path), error = function(e) list(state = "running"))
}
