# dragonfarm app image (DRAFT: written 2026-10-18, not yet built or run;
# see deploy/README.md). R with dragonfarm from R-universe; the Python
# environment is built from the package's lock on first start and kept in
# a volume, so the image stays small and rebuilds are quick.
FROM rocker/r-ver:4.6.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      libpq-dev libssl-dev libcurl4-openssl-dev libxml2-dev curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN Rscript -e 'install.packages(c("dragonfarm", "RPostgres", "keyring"), repos = c("https://tejas4patel.r-universe.dev", "https://cloud.r-project.org"))'

# Runs, document sets and the Python environment live in volumes.
ENV DRAGONFARM_RUNS_DIR=/data/runs \
    RETICULATE_CACHE_DIR=/data/python \
    UV_CACHE_DIR=/data/python/uv

EXPOSE 3838
CMD ["Rscript", "-e", "shiny::runApp(dragonfarm::dragon_app(), host = '0.0.0.0', port = 3838, launch.browser = FALSE)"]
