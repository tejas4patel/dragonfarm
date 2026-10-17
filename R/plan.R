# Plans: what a multi-step task will do, before it starts. For each step,
# what it does, whether it uses the GPU, whether anything leaves the machine,
# and how long it took before (from this runs folder's history; no guess
# when there is none). Starting the task after seeing the plan is recorded
# as the approval, with the plan itself (D-8: a person approves training and
# anything leaving the machine).

# Where a judge or teacher runs: a model id or folder runs here on the GPU;
# a Claude API function sends prompts and replies to Anthropic; any other
# function is the user's own code, which may send data anywhere.
judge_place <- function(judge) {
  if (is.character(judge)) return(list(gpu = TRUE, leaves = NA_character_, label = basename(judge)))
  label <- attr(judge, "label") %||% ""
  if (startsWith(label, "anthropic:")) {
    return(list(gpu = FALSE, leaves = "Anthropic (Claude API)", label = sub("^anthropic:", "", label)))
  }
  list(gpu = FALSE, leaves = "your own function (it may send data elsewhere)", label = if (nzchar(label)) label else "a function")
}

step_plan_row <- function(step) {
  s <- step
  switch(s$type,
    train = list(what = sprintf("Fine-tune on %d rows", nrow(s$dataset$data)), gpu = TRUE, leaves = NA_character_),
    prefer = list(what = sprintf("Preference training (%s) from the previous run", toupper(s$method)), gpu = TRUE, leaves = NA_character_),
    reinforce = list(what = "Reinforcement learning (GRPO) from the previous run", gpu = TRUE, leaves = NA_character_),
    synthesize_pairs = {
      j <- judge_place(s$judge)
      list(what = sprintf("Sample %d prompts %d times each; %s ranks the replies into pairs", s$n, s$n_samples, j$label),
           gpu = TRUE, leaves = j$leaves)
    },
    judge = {
      j <- judge_place(s$judge)
      list(what = sprintf("%s compares the run with %s on %d prompts", j$label, s$against, s$n), gpu = TRUE, leaves = j$leaves)
    },
    evaluate = list(what = "Score the latest run on held-out rows", gpu = TRUE, leaves = NA_character_),
    merge = list(what = "Merge the adapter into the base model", gpu = FALSE, leaves = NA_character_),
    publish = list(what = sprintf("Upload the model to Hugging Face (%s)", s$repo), gpu = FALSE,
                   leaves = sprintf("Hugging Face (%s, %s)", s$repo, if (isTRUE(s$private)) "private" else "public")),
    list(what = s$type, gpu = NA, leaves = NA_character_)
  )
}

# Seconds each past step of this type took, from pipeline records, plus
# finished training runs of the same model for the training steps.
step_history_seconds <- function(type, model, runs_dir) {
  secs <- numeric()
  for (f in list.files(file.path(runs_dir, "pipelines"), pattern = "[.]json$", full.names = TRUE)) {
    rec <- tryCatch(read_json_retry(f), error = function(e) NULL)
    if (is.null(rec) || !identical(rec$model, model)) next
    for (st in rec$steps) {
      if (identical(st$type, type) && identical(st$state, "succeeded") && !is.null(st$started_at) && !is.null(st$finished_at)) {
        secs <- c(secs, as.numeric(difftime(parse_iso(st$finished_at), parse_iso(st$started_at), units = "secs")))
      }
    }
  }
  if (identical(type, "train") && !length(secs)) {
    runs <- tryCatch(dragon_runs(runs_dir), error = function(e) NULL)
    if (!is.null(runs) && nrow(runs)) {
      for (d in runs$dir[runs$state %in% "succeeded" & runs$model %in% model & runs$stage %in% "sft"]) {
        st <- tryCatch(read_json_retry(file.path(d, "status.json")), error = function(e) NULL)
        if (!is.null(st$started_at) && !is.null(st$finished_at)) {
          secs <- c(secs, as.numeric(difftime(parse_iso(st$finished_at), parse_iso(st$started_at), units = "secs")))
        }
      }
    }
  }
  secs[is.finite(secs) & secs >= 0]
}

parse_iso <- function(x) as.POSIXct(sub("Z$", "", x), format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")

# One row per step: n, what, gpu, leaves (where data goes, NA for nowhere),
# estimate_s (median of past runs, NA when there are none) and past (how
# many past runs the estimate is from).
pipeline_plan <- function(model, steps, runs_dir = dragon_runs_dir()) {
  model_id <- if (inherits(model, "dragon_run")) model$id else model
  rows <- lapply(seq_along(steps), function(i) {
    r <- step_plan_row(steps[[i]])
    h <- step_history_seconds(steps[[i]]$type, model_id, runs_dir)
    data.frame(n = i, step = steps[[i]]$type, what = r$what, gpu = isTRUE(r$gpu), leaves = r$leaves,
               estimate_s = if (length(h)) stats::median(h) else NA_real_, past = length(h))
  })
  do.call(rbind, rows)
}

format_duration <- function(s) {
  if (is.na(s)) return("no estimate yet")
  if (s < 90) return(sprintf("about %d s", round(s)))
  if (s < 5400) return(sprintf("about %d min", round(s / 60)))
  sprintf("about %.1f h", s / 3600)
}

# The plan as the app shows it.
plan_ui <- function(plan) {
  leaves <- unique(stats::na.omit(plan$leaves))
  known <- plan$estimate_s[!is.na(plan$estimate_s)]
  shiny::tagList(
    shiny::tags$ol(class = "plan",
      lapply(seq_len(nrow(plan)), function(i) {
        p <- plan[i, ]
        shiny::tags$li(
          shiny::span(class = "plan-what", p$what),
          shiny::span(class = "plan-tags",
            if (isTRUE(p$gpu)) shiny::span(class = "plan-tag gpu", "GPU"),
            if (!is.na(p$leaves)) shiny::span(class = "plan-tag out", paste("leaves this machine:", p$leaves)),
            shiny::span(class = "plan-tag time", format_duration(p$estimate_s)))
        )
      })),
    shiny::p(class = "hint",
      if (length(known)) sprintf("Known steps add up to %s%s.", format_duration(sum(known)),
                                 if (anyNA(plan$estimate_s)) "; the others have not run here before" else "")
      else "No step has run here before, so there is no time estimate yet.",
      if (length(leaves)) paste0(" Starting it sends data to ", paste(leaves, collapse = " and "), ".") else " Nothing leaves this machine.")
  )
}

# Record that a person saw this plan and started it.
plan_record_approval <- function(kind, plan, runs_dir = dragon_runs_dir()) {
  store_record_event("approval", kind, ok = TRUE,
                     detail = list(plan = lapply(seq_len(nrow(plan)), function(i) as.list(plan[i, c("n", "step", "what", "gpu", "leaves")]))),
                     runs_dir = runs_dir)
}
