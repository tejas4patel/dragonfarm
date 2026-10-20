# dragonfarm app image (DRAFT: see deploy/README.md for what has been
# tested). R with dragonfarm from R-universe; its dependencies come as
# ready-built Linux binaries from the image's package mirror (p3m.dev), so
# nothing has to compile. The Python environment is built from the package's
# lock on first start and kept in a volume, so the image stays small and
# rebuilds are quick.
FROM rocker/r-ver:4.6.1

# Libraries the binary packages link against (Postgres, TLS, curl, XML, PNG,
# zlib, libuv for fs/httpuv).
RUN apt-get update && apt-get install -y --no-install-recommends \
      libpq5 libssl3t64 libcurl4t64 libxml2 libpng16-16t64 zlib1g libuv1t64 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# install.packages() only warns when a package fails, so check afterwards and
# stop the build if anything is missing.
RUN Rscript -e 'repos <- c("https://tejas4patel.r-universe.dev", getOption("repos")); \
  install.packages(c("dragonfarm", "RPostgres", "keyring"), repos = repos); \
  missing <- setdiff(c("dragonfarm", "RPostgres", "keyring", "shiny"), rownames(installed.packages())); \
  if (length(missing)) stop("not installed: ", paste(missing, collapse = ", "))'

# Runs, document sets and the Python environment live in volumes.
ENV DRAGONFARM_RUNS_DIR=/data/runs \
    RETICULATE_CACHE_DIR=/data/python \
    UV_CACHE_DIR=/data/python/uv

EXPOSE 3838
CMD ["Rscript", "-e", "shiny::runApp(dragonfarm::dragon_app(), host = '0.0.0.0', port = 3838, launch.browser = FALSE)"]
