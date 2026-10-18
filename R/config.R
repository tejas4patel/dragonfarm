#' LoRA settings
#'
#' @param r Rank of the adapter matrices. Higher learns more, costs more memory.
#' @param alpha Scaling factor. A common rule is `alpha = 2 * r`.
#' @param dropout Dropout applied to the adapter input.
#' @param target_modules `"auto"` adapts every linear layer except the output
#'   head (peft's `"all-linear"`). Or a character vector of module names such
#'   as `c("q_proj", "v_proj")`.
#' @return A `dragon_lora` object.
#' @export
#' @examples
#' dragon_lora(r = 8, alpha = 16)
dragon_lora <- function(r = 16, alpha = 32, dropout = 0.05, target_modules = "auto") {
  check_number(r, "r", min = 1, max = 1024, integer = TRUE)
  check_number(alpha, "alpha", min = 0.001)
  check_number(dropout, "dropout", min = 0, max = 0.99)
  if (!is.character(target_modules) || !length(target_modules)) {
    cli::cli_abort("{.arg target_modules} must be \"auto\" or a character vector of module names.")
  }
  structure(
    list(r = as.integer(r), alpha = alpha, dropout = dropout, target_modules = target_modules),
    class = "dragon_lora"
  )
}

#' Training settings
#'
#' @param epochs Passes over the training data. Ignored when `max_steps` is set.
#' @param learning_rate Peak learning rate. `2e-4` is a good LoRA default.
#' @param batch_size Examples per device per step.
#' @param grad_accum Steps to accumulate before an optimizer update. Effective
#'   batch size is `batch_size * grad_accum`.
#' @param max_seq_len Maximum tokens per example. Longer examples are truncated.
#' @param max_steps Stop after this many optimizer steps. `NULL` trains for `epochs`.
#' @param warmup_ratio Fraction of steps used to warm up the learning rate.
#' @param weight_decay Weight decay for the optimizer.
#' @param logging_steps Steps between progress rows.
#' @param save_steps Steps between checkpoints.
#' @param gradient_checkpointing Trade compute for memory. Turn on if you run
#'   out of GPU memory.
#' @param eval_batch_size Held-out rows scored per forward pass, during
#'   training and at the end. Defaults to 1: scoring materializes a
#'   `batch x tokens x vocabulary` tensor, so at long `max_seq_len` a larger
#'   value can run a GPU out of memory after training has already succeeded.
#'   Raise it for speed on a large GPU.
#' @param seed Random seed.
#' @param ... Extra named arguments passed straight to `TrainingArguments`.
#' @return A `dragon_train_args` object.
#' @export
#' @examples
#' dragon_train_args(epochs = 1, learning_rate = 1e-4)
dragon_train_args <- function(epochs = 3, learning_rate = 2e-4, batch_size = 4,
                              grad_accum = 4, max_seq_len = 1024, max_steps = NULL,
                              warmup_ratio = 0.03, weight_decay = 0,
                              logging_steps = 5, save_steps = 100,
                              gradient_checkpointing = FALSE, eval_batch_size = 1, seed = 42, ...) {
  check_number(epochs, "epochs", min = 0.01)
  check_number(eval_batch_size, "eval_batch_size", min = 1, integer = TRUE)
  check_number(learning_rate, "learning_rate", min = 1e-8, max = 1)
  check_number(batch_size, "batch_size", min = 1, integer = TRUE)
  check_number(grad_accum, "grad_accum", min = 1, integer = TRUE)
  check_number(max_seq_len, "max_seq_len", min = 16, integer = TRUE)
  check_number(max_steps, "max_steps", min = 1, integer = TRUE, allow_null = TRUE)
  check_number(warmup_ratio, "warmup_ratio", min = 0, max = 1)
  check_number(weight_decay, "weight_decay", min = 0)
  check_number(logging_steps, "logging_steps", min = 1, integer = TRUE)
  check_number(save_steps, "save_steps", min = 1, integer = TRUE)
  check_number(seed, "seed", integer = TRUE)
  extra <- list(...)
  if (length(extra) && (is.null(names(extra)) || any(!nzchar(names(extra))))) {
    cli::cli_abort("Extra arguments in {.arg ...} must all be named.")
  }
  if (!length(extra)) extra <- empty_object()
  structure(
    list(
      epochs = epochs, learning_rate = learning_rate,
      batch_size = as.integer(batch_size), grad_accum = as.integer(grad_accum),
      max_seq_len = as.integer(max_seq_len),
      max_steps = if (!is.null(max_steps)) as.integer(max_steps),
      warmup_ratio = warmup_ratio, weight_decay = weight_decay,
      logging_steps = as.integer(logging_steps), save_steps = as.integer(save_steps),
      gradient_checkpointing = isTRUE(gradient_checkpointing),
      eval_batch_size = as.integer(eval_batch_size),
      seed = as.integer(seed), extra = extra
    ),
    class = "dragon_train_args"
  )
}

#' Hardware settings
#'
#' @param device `"auto"` picks CUDA, then Apple MPS, then CPU. Or name one.
#' @param dtype `"auto"` picks bfloat16 on GPUs that support it, float16 on
#'   older GPUs, and float32 elsewhere.
#' @param load_in_4bit Load the base model in 4-bit through bitsandbytes
#'   (QLoRA when training). Needs an NVIDIA GPU; works on Linux and Windows.
#'   For generation, prefer the `load_in_4bit` argument of
#'   [dragon_backend_local()], which decides per model.
#' @return A `dragon_hardware` object.
#' @examples
#' dragon_hardware()
#' dragon_hardware(device = "cpu")
#' @export
dragon_hardware <- function(device = c("auto", "cuda", "mps", "cpu"),
                            dtype = c("auto", "bfloat16", "float16", "float32"),
                            load_in_4bit = FALSE) {
  device <- match.arg(device)
  dtype <- match.arg(dtype)
  structure(
    list(device = device, dtype = dtype, load_in_4bit = isTRUE(load_in_4bit)),
    class = "dragon_hardware"
  )
}

build_config <- function(run_id, model, files, lora, args, hardware, n_samples,
                         revision = NULL, trust_remote_code = FALSE,
                         stage = "sft", prefer = NULL, base = NULL, reinforce = NULL) {
  list(
    schema_version = 1L,
    run_id = run_id,
    created_at = now_iso(),
    stage = stage,
    model = list(
      id = model, revision = revision %||% preset_revision(model), trust_remote_code = isTRUE(trust_remote_code),
      allow_pickle = allow_pickle_weights(),
      base_run = base$run_id,
      base_adapters = if (length(base$adapters)) as.list(base$adapters)
    ),
    prefer = if (identical(stage, "prefer")) list(method = prefer$method, beta = prefer$beta),
    reinforce = if (identical(stage, "reinforce")) reinforce,
    data = list(
      train = files$train, eval = files$eval, format = files$format %||% "messages",
      n_train = files$n_train, n_eval = files$n_eval
    ),
    lora = list(
      r = lora$r, alpha = lora$alpha, dropout = lora$dropout,
      target_modules = if (identical(lora$target_modules, "auto")) "auto" else as.list(lora$target_modules)
    ),
    train = list(
      epochs = args$epochs,
      learning_rate = args$learning_rate,
      per_device_batch_size = args$batch_size,
      per_device_eval_batch_size = args$eval_batch_size,
      gradient_accumulation = args$grad_accum,
      max_seq_len = args$max_seq_len,
      max_steps = args$max_steps,
      warmup_ratio = args$warmup_ratio,
      weight_decay = args$weight_decay,
      logging_steps = args$logging_steps,
      save_steps = args$save_steps,
      gradient_checkpointing = args$gradient_checkpointing,
      seed = args$seed,
      extra = args$extra
    ),
    hardware = list(device = hardware$device, dtype = hardware$dtype, load_in_4bit = hardware$load_in_4bit),
    eval = list(n_samples = as.integer(n_samples))
  )
}

# Reverse of build_config for the parts that have R constructors.
config_to_objects <- function(cfg) {
  tm <- cfg$lora$target_modules
  list(
    model = cfg$model$id,
    lora = dragon_lora(
      r = cfg$lora$r, alpha = cfg$lora$alpha, dropout = cfg$lora$dropout,
      target_modules = if (is.list(tm)) unlist(tm) else tm
    ),
    args = do.call(dragon_train_args, c(
      list(
        epochs = cfg$train$epochs, learning_rate = cfg$train$learning_rate,
        batch_size = cfg$train$per_device_batch_size, grad_accum = cfg$train$gradient_accumulation,
        max_seq_len = cfg$train$max_seq_len, max_steps = cfg$train$max_steps,
        warmup_ratio = cfg$train$warmup_ratio, weight_decay = cfg$train$weight_decay,
        logging_steps = cfg$train$logging_steps, save_steps = cfg$train$save_steps,
        gradient_checkpointing = cfg$train$gradient_checkpointing,
        # Runs written before 0.4.0 have no eval batch size; they evaluated at the training batch size.
        eval_batch_size = cfg$train$per_device_eval_batch_size %||% 1L,
        seed = cfg$train$seed
      ),
      cfg$train$extra
    )),
    hardware = dragon_hardware(cfg$hardware$device, cfg$hardware$dtype, cfg$hardware$load_in_4bit)
  )
}
