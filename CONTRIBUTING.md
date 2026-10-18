# Contributing to dragonfarm

Thanks for your interest. Bug reports, documentation fixes, and small
features are all welcome. This page says how to set up, test, and send
changes.

## Reporting a problem

Open an issue with the output of
[`dragon_check()`](https://dragonfarm.dev/reference/dragon_check.md),
the code you ran, and what happened. The issue form asks for these. For
a training run that went wrong, the `log.txt` in the run folder
([`dragon_runs_dir()`](https://dragonfarm.dev/reference/dragon_runs_dir.md))
is the most useful attachment.

## Setting up

``` r

# install.packages("pak")
pak::pak(c("devtools", "testthat", "pkgdown"))
devtools::load_all()
dragon_check()
```

[`dragon_check()`](https://dragonfarm.dev/reference/dragon_check.md)
builds the Python environment on first use (torch, transformers, peft; 2
to 3 GB) and reports the GPU it found. Everything in
`inst/python/dragonfarm` is plain Python run through that environment;
no reticulate objects cross the boundary except strings and JSON.

## Running the tests

| What | Command | Needs |
|----|----|----|
| R unit tests (about 2,300 expectations) | [`devtools::test()`](https://devtools.r-lib.org/reference/test.html) | R only, a few minutes |
| Python unit tests | see below | the Python environment |
| Integration tests (real training) | `Sys.setenv(DRAGONFARM_INTEGRATION = "true"); devtools::test(filter = "integration")` | a GPU helps; downloads small models |

The Python tests use a tiny runner so they work without pytest:

``` r

py <- dragonfarm:::dragon_python()
system2(py, "inst/python/tests/run.py", env = "PYTHONPATH=inst/python")
```

Continuous integration runs the first two on every push and the
integration suite on a CPU runner, so a change that passes locally
should pass there. It also runs `lintr::lint_package()` with the
correctness checks in `.lintr` (static analysis, not style); run it
before sending a change.

## Before you send a change

- [`devtools::document()`](https://devtools.r-lib.org/reference/document.html)
  after touching roxygen comments.
- `devtools::check(args = "--as-cran")` should be clean. R sources must
  be ASCII outside comments: write the escape `\u203a`, not the
  character.
- [`pkgdown::check_pkgdown()`](https://pkgdown.r-lib.org/reference/check_pkgdown.html)
  if you added an exported function; every exported topic has to appear
  in the reference index in `_pkgdown.yml`, and a unit test enforces
  this.
- Add a line to `NEWS.md` for anything a user would notice.
- Changed how a file is read or chunked
  (`inst/python/dragonfarm/documents.py`)? Bump `READER_VERSION` there.
  Sets are reused by checksum, so without the bump existing document
  sets keep the chunks the old code produced. Then run
  `python scripts/retrieval_eval.py` with the package’s Python before
  and after on a few real document sets; it prints <hit@1>/4/8 for both
  search modes.
- Add a test. Shiny modules are tested with
  [`shiny::testServer`](https://rdrr.io/pkg/shiny/man/testServer.html);
  Python helpers have tests under `inst/python/tests`.
- Never commit credentials, API keys, or tokens, including in scripts
  under `scripts/`. API keys come from environment variables such as
  `ANTHROPIC_API_KEY`, never from a file in the repository.

## Sending it

Fork the repository, make a branch, and open a pull request against
`main` with a short description of what changed and why. Maintainers
commit directly to `main`; outside changes come in through pull requests
so the checks run first.

## Where things live

| Path | Contents |
|----|----|
| `R/` | the R API, the Shiny modules (`mod_*.R`), backends, run bookkeeping |
| `inst/python/dragonfarm/` | training, evaluation, document ingestion, retrieval, the inference worker |
| `inst/python/tests/` | Python unit tests |
| `inst/app/www/` | app CSS and JavaScript |
| `inst/extdata/` | example tickets and policy documents |
| `vignettes/` | the quickstart and the articles on the site |
| `architecture/` | design notes written before larger features |
| `scripts/` | measurement scripts behind numbers quoted in the docs |

## Releasing (maintainer)

1.  Bump `Version:` in DESCRIPTION and change the top NEWS heading to
    that version. Update `cran-comments.md`.

2.  `R CMD build` and `R CMD check --as-cran` on the tarball: no errors
    or warnings; explain any note in `cran-comments.md`.

3.  Submit at <https://cran.r-project.org/submit.html>. CRAN asks for at
    most one update every one to two months.

4.  Once CRAN accepts it, tag the release commit and create the GitHub
    release from that version’s NEWS section, so the repository’s
    “Latest” release matches CRAN:

    ``` bash
    git tag v0.4.0 && git push origin v0.4.0
    gh release create v0.4.0 --title "dragonfarm 0.4.0" --notes-file notes.md --latest
    ```

5.  Add `.9000` to the version for development.

## Conduct

Be kind and assume good faith. Harassment or personal attacks in issues,
pull requests, or discussions are not acceptable and will be removed.
