## Submission

This is a feature release, 0.4.0. Its main addition is a document route:
functions that read PDF, Word, HTML, Markdown, spreadsheet files and web pages
into chunked "document sets", retrieve the relevant chunks for a question,
answer with cited sources, and turn the documents into training data. As in
earlier versions, all heavy work runs in a separate 'Python' process; no
'Python' code runs during R CMD check, and examples and tests that need it are
skipped on CRAN.

## R CMD check results

Local `R CMD check --as-cran` on the 0.4.0 tarball (Windows 11, R 4.6.1,
2026-10-17): 0 errors | 0 warnings | 1 note. The note is the incoming check's
"Days since last update", from a run made five days after 0.3.4; this release is
submitted at least a month after 0.3.4, so it should not appear.

The "detritus in the temp directory" NOTE reported with 0.3.4 is fixed: a
test started `Rscript -e` and stopped it, and on Windows that leaves an
`Rscript*` file in the temporary folder. The test now runs a script file in
its own temporary folder, and the package's background pipelines also run
from a script file.

## Changes that touch the check

* New imports 'DBI' and 'RSQLite' for a small catalog of document sets,
  runs, model versions, and an append-only event log (including a record of
  each answer and of anything sent off the machine), kept in one SQLite file
  in the user's runs folder (never in the package or home directory unless
  the user points the runs folder there). Tests use temporary folders.
* New suggested packages 'S7' and 'mcptools' for `dragon_ellmer_tools()` and
  `dragon_mcp_server()`, which hand the package's tools to other agents; the
  examples and tests that need them are skipped when they are absent.
* New file `inst/python/requirements.lock` (about 100 KB): the 'Python'
  packages pinned with hashes, for administrators who install without the
  internet. Nothing reads it during the check.

* New 'Python' requirements for the document readers ('pypdf',
  'cryptography' for encrypted PDFs, 'python-docx', 'openpyxl') and for
  4-bit loading ('bitsandbytes', skipped on macOS). They are declared with `reticulate::py_require()` and installed
  only when a user first runs a function that needs 'Python'.
* New import: 'commonmark', already a dependency of 'shiny', used to show
  model replies in the app as formatted text.
* New example data under `inst/extdata/policies/` (three short Markdown
  files, about 16 KB on disk).
* `Language: en-GB` added to DESCRIPTION, with `inst/WORDLIST`.
* Title and Description now describe the document route as well as the
  table route.

## Test environments

* local Windows 11, R 4.6.1
* GitHub Actions: macOS (release), Windows (release), Ubuntu (devel,
  release, oldrel-1)
