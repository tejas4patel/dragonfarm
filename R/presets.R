#' Recommended base models
#'
#' A table of instruction-tuned models that work well with LoRA on a single
#' consumer GPU, from a 135M model that trains on a CPU to a 7B that trains
#' in 4-bit on an 8 GB NVIDIA card. Any Hugging Face causal language model id
#' can be passed to [dragon_train()]; these are good starting points.
#'
#' Which size to pick depends on the task. Measured on an 8 GB laptop GPU
#' (see the "Choosing a model size" article on the package website): for
#' answering from documents, writing training questions, or fine-tuning on
#' documents, use the 7B in 4-bit, or the 3B with less memory; models below
#' 3B are wrong more often (untrained, the 0.5B on 14 of 55 test questions,
#' the 7B on none). For a fixed
#' output format such as JSON fields or labels, the 0.5B and 1.5B reach the
#' same score as larger models in a few minutes of training.
#'
#' @return A data frame with columns `id`, `params`, `license`, `gated`,
#'   `rank`, `min_vram_gb`, `load_in_4bit` (whether it needs 4-bit loading to
#'   fit `min_vram_gb`), and `notes`.
#' @export
#' @examples
#' dragon_presets()
dragon_presets <- function() {
  data.frame(
    id = c(
      "HuggingFaceTB/SmolLM2-135M-Instruct",
      "HuggingFaceTB/SmolLM2-360M-Instruct",
      "Qwen/Qwen2.5-0.5B-Instruct",
      "google/gemma-3-1b-it",
      "meta-llama/Llama-3.2-1B-Instruct",
      "Qwen/Qwen2.5-1.5B-Instruct",
      "HuggingFaceTB/SmolLM2-1.7B-Instruct",
      "Qwen/Qwen2.5-3B-Instruct",
      "Qwen/Qwen2.5-7B-Instruct"
    ),
    # The Hub commit each preset is pinned to (checked 2026-10-17), so a run
    # trains and answers with exactly the weights it was tested with.
    revision = c(
      "12fd25f77366fa6b3b4b768ec3050bf629380bac", "a10cc1512eabd3dde888204e902eca88bddb4951",
      "7ae557604adf67be50417f59c2c2f167def9a775", "dcc83ea841ab6100d6b47a070329e1ba4cf78752",
      "9213176726f574b556790deb65791e0c5aa438b6", "989aa7980e4cf806f80c7fef2b1adb7bc71aa306",
      "31b70e2e869a7173562077fd711b654946d38674", "aa8e72537993ba99e69dfaafa59ed015b17504d1",
      "a09a35458c702b33eeacc393d103063234e8bc28"
    ),
    params = c("135M", "360M", "0.5B", "1B", "1.2B", "1.5B", "1.7B", "3B", "7B"),
    license = c("Apache 2.0", "Apache 2.0", "Apache 2.0", "Gemma", "Llama 3.2", "Apache 2.0", "Apache 2.0",
                "Qwen Research", "Apache 2.0"),
    gated = c(FALSE, FALSE, FALSE, TRUE, TRUE, FALSE, FALSE, FALSE, FALSE),
    rank = c(8L, 8L, 16L, 16L, 16L, 16L, 16L, 16L, 16L),
    min_vram_gb = c(2, 3, 3, 5, 5, 7, 8, 5, 8),
    load_in_4bit = c(FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, TRUE, TRUE),
    notes = c(
      "Fastest. Trains on a CPU in minutes. Used by the package tests.",
      "Tiny. For trying the workflow on a laptop.",
      "App default. Fixed formats such as JSON: 20 of 20 after 3 minutes of training. Wrong on 14 of 55 document questions.",
      "Needs a Hugging Face token.",
      "Needs a Hugging Face token.",
      "Fixed formats and house style. Wrong on 6 of 55 document questions (the 7B on none).",
      "Largest of the small presets. Turn on gradient checkpointing on 8 GB cards.",
      "Documents on a smaller card: declines what the documents do not cover. Trains in 4-bit; research licence.",
      "Best for documents: answering, writing training questions, fine-tuning. 4-bit, batch size 1 on an 8 GB NVIDIA card."
    ),
    stringsAsFactors = FALSE
  )
}

preset_for <- function(model) {
  p <- dragon_presets()
  hit <- p[p$id == model, , drop = FALSE]
  if (nrow(hit)) hit else NULL
}

# Parameter count in billions read from a model id ("Qwen2.5-7B-Instruct" ->
# 7, "SmolLM2-135M-Instruct" -> 0.135), or NA when the id does not say. Same
# rule as model_size_b() in the Python package.
model_size_b <- function(model_id) {
  name <- basename(sub("/+$", "", as.character(model_id %||% "")))
  m <- regmatches(name, gregexpr("[0-9]+([.][0-9]+)?[bBmM](?![A-Za-z])", name, perl = TRUE))[[1]]
  if (!length(m)) return(NA_real_)
  num <- as.numeric(sub("[bBmM]$", "", m))
  unit <- tolower(substring(m, nchar(m)))
  max(ifelse(unit == "m", num / 1000, num))
}

# The app and the site call model sizes by dragon life stage. Only a label:
# nothing in the package depends on it.
dragon_stage <- function(size_b) {
  if (is.null(size_b) || is.na(size_b)) return("")
  if (size_b < 0.4) "Egg"
  else if (size_b < 1) "Hatchling"
  else if (size_b < 2.5) "Drake"
  else if (size_b < 5) "Wyvern"
  else "Elder"
}

# Should training load this model in 4-bit (QLoRA)? Training needs room for
# activations as well as the weights, so the bar is lower than for answering:
# bf16 weights (about 2.1 GB per billion parameters) over 60% of GPU memory.
# On an 8 GB card a 3B or 7B trains in 4-bit and a 1.5B does not. NA when
# there is no NVIDIA GPU or the model id does not give a size.
suggest_train_4bit <- function(model_id, hw = NULL) {
  size <- model_size_b(model_id)
  if (is.na(size)) return(NA)
  if (is.null(hw)) return(if (size >= 6) TRUE else NA)
  if (!identical(hw$device, "cuda")) return(NA)
  size * 2.1 > 0.6 * as.numeric(hw$vram_gb %||% 0)
}

# Batch settings for a 4-bit run: batch size 1, with gradient accumulation
# raised so the effective batch (batch size x accumulation) stays the same.
batch_for_4bit <- function(batch_size, grad_accum) {
  b <- suppressWarnings(as.integer(batch_size))
  a <- suppressWarnings(as.integer(grad_accum))
  if (is.na(b) || b < 1) b <- 1L
  if (is.na(a) || a < 1) a <- 1L
  list(batch_size = 1L, grad_accum = b * a)
}

# The pinned Hub commit for a preset model id; NULL for anything else.
preset_revision <- function(model) {
  if (!is.character(model) || length(model) != 1) return(NULL)
  p <- dragon_presets()
  r <- p$revision[match(model, p$id)]
  if (is.na(r)) NULL else r
}

# Weights in the pickle (.bin) format can run code when loaded, so models are
# loaded from safetensors only unless this option is set.
allow_pickle_weights <- function() isTRUE(getOption("dragonfarm.allow_pickle_weights", FALSE))
