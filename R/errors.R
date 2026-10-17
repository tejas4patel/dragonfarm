# Messages for the error codes Python sends with a failure
# (inst/python/dragonfarm/errors.py). Python names what went wrong while the
# exception is at hand; this is the one place that words it for people.
# `error` is Python's own text ("Type: message"); `code` may be missing for a
# status file written by an older version, or a server that sends no code.
error_message <- function(error, code = NULL) {
  error <- error %||% "unknown error"
  code <- code %||% legacy_error_code(error)
  switch(code,
    MODEL_NOT_FOUND = model_not_found_message(error),
    OUT_OF_MEMORY = if (grepl("ran out of memory", error, fixed = TRUE)) error else paste0(
      error, "\nThis usually means the GPU ran out of memory. Try batch size 1 with gradient accumulation raised to ",
      "keep the same effective batch, turn on gradient checkpointing, shorten the maximum sequence length, or ",
      "load the model in 4-bit."),
    PICKLE_WEIGHTS_ONLY = paste(
      "This model's weights exist only in the pickle (.bin) format, which can run code when loaded, so dragonfarm",
      "does not load it. Use a model that ships safetensors, or, if you trust this one, set",
      "options(dragonfarm.allow_pickle_weights = TRUE).", paste0("(", error, ")")),
    error
  )
}

# Codes for text that came without one.
legacy_error_code <- function(error) {
  if (grepl("is not a local folder and is not a valid model identifier", error, fixed = TRUE)) return("MODEL_NOT_FOUND")
  "UNKNOWN"
}

# transformers' message for a model id that is neither a folder nor on the
# Hugging Face Hub talks about private repositories and tokens, while most of
# the time the id has a typo. Say what happened, and suggest the closest preset.
model_not_found_message <- function(error) {
  m <- regmatches(error, regexec("([^ ]+) is not a local folder and is not a valid model identifier", error))[[1]]
  id <- if (length(m) >= 2) m[2] else NULL
  if (is.null(id)) {
    return(paste("That model could not be found: no folder by that name, and no model with that id on Hugging Face.",
                 "(A private or gated model also needs a Hugging Face token: `hf auth login`.)"))
  }
  known <- dragon_presets()$id
  d <- utils::adist(tolower(id), tolower(known))[1, ]
  hint <- if (min(d) <= 3) sprintf(" Did you mean \"%s\"?", known[which.min(d)]) else ""
  sprintf(paste0("There is no model called \"%s\": no folder by that name, and no model with that id on ",
                 "Hugging Face.%s (A private or gated model also needs a Hugging Face token: `hf auth login`.)"), id, hint)
}
