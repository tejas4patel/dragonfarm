#' R code that reproduces a run
#'
#' Every run, including ones started from the Shiny app, can be replayed as
#' a script. The dataset path is the original source when it was a file. A
#' run that continued from an earlier run refers to that run by directory.
#'
#' @param run A `dragon_run` or run directory.
#' @return A single string of R code.
#' @examples
#' if (interactive()) {
#' run <- dragon_run(file.path(dragon_runs_dir(), dragon_runs()$id[1]))
#' cat(dragon_code(run))
#' }
#' @export
dragon_code <- function(run) {
  run <- dragon_run(run)
  cfg <- run_config(run)
  meta <- if (file.exists(run_path(run, "dataset.json"))) read_json(run_path(run, "dataset.json")) else list()
  src <- meta$source %||% "path/to/your/data.csv"
  m <- meta$mapping %||% list(prompt = "prompt", response = "response")
  kind <- m$kind %||% "messages"
  stage <- cfg$stage %||% "sft"
  fmt <- fmt_arg

  lora_line <- sprintf("dragon_lora(r = %d, alpha = %s, dropout = %s, target_modules = %s)",
                       cfg$lora$r, fmt(cfg$lora$alpha), fmt(cfg$lora$dropout),
                       if (is.list(cfg$lora$target_modules)) fmt(unlist(cfg$lora$target_modules)) else fmt(cfg$lora$target_modules))
  t <- cfg$train
  args_parts <- c(
    sprintf("epochs = %s", fmt(t$epochs)),
    sprintf("learning_rate = %s", fmt(t$learning_rate)),
    sprintf("batch_size = %d", t$per_device_batch_size),
    sprintf("grad_accum = %d", t$gradient_accumulation),
    sprintf("max_seq_len = %d", t$max_seq_len),
    if (!is.null(t$max_steps)) sprintf("max_steps = %d", t$max_steps),
    if (isTRUE(t$gradient_checkpointing)) "gradient_checkpointing = TRUE",
    if (!is.null(t$per_device_eval_batch_size) && t$per_device_eval_batch_size != 1L)
      sprintf("eval_batch_size = %d", t$per_device_eval_batch_size),
    sprintf("seed = %d", t$seed)
  )
  hw <- cfg$hardware
  hw_line <- sprintf("dragon_hardware(device = %s, dtype = %s%s)", fmt(hw$device), fmt(hw$dtype),
                     if (isTRUE(hw$load_in_4bit)) ", load_in_4bit = TRUE" else "")
  system_part <- if (!is.null(m$system)) paste0(", system = ", fmt(m$system)) else ""
  map_line <- if (kind == "conversations") {
    ""
  } else if (kind == "pairs") {
    sprintf("dragon_map_pairs(prompt = %s, chosen = %s, rejected = %s%s)",
            fmt(m$prompt), fmt(m$chosen), fmt(m$rejected), system_part)
  } else if (kind == "prompts") {
    sprintf("dragon_map_prompts(prompt = %s%s%s)", fmt(m$prompt),
            if (!is.null(m$reference)) paste0(", reference = ", fmt(m$reference)) else "", system_part)
  } else {
    sprintf("dragon_map(prompt = %s, response = %s%s)", fmt(m$prompt), fmt(m$response), system_part)
  }

  base_run <- cfg$model$base_run
  model_lines <- if (!is.null(base_run)) {
    c(sprintf("    # continues from the earlier stage in %s", base_run),
      sprintf("    model = dragon_run(%s),", fmt(file.path(dirname(run$dir), base_run))))
  } else {
    sprintf("    model = %s,", fmt(cfg$model$id))
  }
  fn <- switch(stage, prefer = "dragon_prefer", reinforce = "dragon_reinforce", "dragon_train")
  stage_lines <- if (stage == "prefer") {
    c(sprintf("    method = %s,", fmt(cfg$prefer$method)), sprintf("    beta = %s,", fmt(cfg$prefer$beta)))
  } else if (stage == "reinforce") {
    rl <- cfg$reinforce
    rewards <- vapply(rl$rewards, reward_code, character(1))
    c("    rewards = list(",
      paste0("      ", rewards, c(rep(",", length(rewards) - 1), "")),
      "    ),",
      sprintf("    group_size = %s, beta = %s, temperature = %s, max_new_tokens = %s,",
              fmt(rl$group_size), fmt(rl$beta), fmt(rl$temperature), fmt(rl$max_new_tokens)))
  }

  data_lines <- if (kind == "conversations") {
    sprintf("run <- dragon_conversations(%s) |>", fmt(src))
  } else {
    c(sprintf("run <- dragon_dataset(%s) |>", fmt(src)), sprintf("  %s |>", map_line))
  }
  paste(
    c(
      "library(dragonfarm)",
      "",
      data_lines,
      sprintf("  %s(", fn),
      model_lines,
      stage_lines,
      sprintf("    lora = %s,", lora_line),
      sprintf("    args = dragon_train_args(%s),", paste(args_parts, collapse = ", ")),
      sprintf("    hardware = %s,", hw_line),
      "    wait = TRUE",
      "  )",
      "",
      "dragon_evaluate(run)",
      "dragon_generate(run, \"Your prompt here\")"
    ),
    collapse = "\n"
  )
}
