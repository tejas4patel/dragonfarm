.onLoad <- function(libname, pkgname) {
  reqs <- dragon_python_requirements()
  # Declare Python dependencies. reticulate resolves them with uv into an
  # ephemeral environment the first time Python is actually needed.
  reticulate::py_require(reqs$packages, python_version = reqs$python_version)
  # The CUDA wheel index is configured on first Python use, not here: CRAN
  # policy forbids changing the user's environment at load time.
  invisible()
}

# On Windows the PyPI torch wheel is CPU-only. When an NVIDIA GPU is present,
# point uv at the CUDA wheel index unless the user has configured indexes
# themselves. Set DRAGONFARM_TORCH_INDEX="" to disable, or to a full index URL
# to override (for example "https://download.pytorch.org/whl/cu128").
#
# uv compares versions across indexes and "2.x.0+cu130" beats "2.x.0" from
# PyPI, so the CUDA build wins as long as the chosen index carries the current
# torch release. The cu130 index tracks releases closely; older indexes lag
# and would lose to the newer CPU wheel on PyPI.
configure_torch_index <- function() {
  if (!is_windows()) return(invisible(FALSE))
  if (nzchar(Sys.getenv("UV_EXTRA_INDEX_URL")) || nzchar(Sys.getenv("UV_INDEX"))) return(invisible(FALSE))
  idx <- Sys.getenv("DRAGONFARM_TORCH_INDEX", unset = "auto")
  if (identical(idx, "")) return(invisible(FALSE))
  if (identical(idx, "auto")) {
    idx <- torch_index_for_driver(nvidia_driver_version())
    if (is.na(idx)) return(invisible(FALSE))
  }
  Sys.setenv(UV_EXTRA_INDEX_URL = idx, UV_INDEX_STRATEGY = "unsafe-best-match")
  invisible(TRUE)
}

# Major driver version from nvidia-smi, or NA when there is no NVIDIA GPU.
nvidia_driver_version <- function() {
  smi <- Sys.which("nvidia-smi")
  if (!nzchar(smi)) return(NA_real_)
  out <- tryCatch(
    suppressWarnings(system2(smi, c("--query-gpu=driver_version", "--format=csv,noheader"), stdout = TRUE, stderr = FALSE)),
    error = function(e) character()
  )
  v <- suppressWarnings(as.numeric(trimws(out[1])))
  if (length(v) != 1 || is.na(v)) NA_real_ else v
}

.onUnload <- function(libpath) {
  store_close_all()
}
