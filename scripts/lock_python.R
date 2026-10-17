# Regenerate inst/python/requirements.lock: every Python package dragonfarm
# needs, pinned with hashes, for all platforms, resolved from PyPI. Run this
# whenever dragon_python_requirements() changes (a test checks the header).
# Admins build environments from the lock; see the "Install without the
# internet" article.
#
#   Rscript scripts/lock_python.R
devtools::load_all(quiet = TRUE)
uv <- Sys.which("uv")
if (!nzchar(uv)) stop("uv is not on the PATH: https://docs.astral.sh/uv/")
reqs <- dragon_python_requirements()
inp <- tempfile(fileext = ".in")
out <- tempfile(fileext = ".txt")
writeLines(reqs$packages, inp)
withr::with_envvar(c(UV_INDEX_URL = NA, UV_EXTRA_INDEX_URL = NA, UV_INDEX = NA), {
  status <- system2(uv, c("pip", "compile", shQuote(inp), "--universal", "--generate-hashes", "--no-header",
                          "--python-version", "3.12", "--index-url", "https://pypi.org/simple", "-o", shQuote(out)))
})
if (status != 0) stop("uv pip compile failed")
header <- c(
  "# dragonfarm: Python packages pinned with hashes, for all platforms, from PyPI.",
  "# Regenerate with scripts/lock_python.R; do not edit by hand.",
  sprintf("# requirements: %s", dragonfarm:::requirements_hash()),
  "# resolved for Python 3.12; build environments with Python 3.12 or later.",
  ""
)
lines <- readLines(out)
lines <- lines[!grepl("^\\s*#", lines)]   # drop uv's "via" comments
writeLines(c(header, lines), "inst/python/requirements.lock")
cat("Wrote inst/python/requirements.lock:", sum(grepl("==", lines)), "packages\n")
