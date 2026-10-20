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
latest on 2026-10-20): 0 errors | 0 warnings | 0 notes. Earlier runs showed
only the incoming check's "Days since last update", which no longer appears.
Nothing is left in the temporary folder.

Every help page has an example. Those that need the 'Python' environment, a
trained run or a GPU are wrapped in `if (interactive())`; the others (listing
runs and document sets, hardware settings, previewing and splitting the
bundled example data) are quick and need nothing outside R.

The "detritus in the temp directory" NOTE reported with 0.3.4 is fixed: a
test started `Rscript -e` and stopped it, and on Windows that leaves an
`Rscript*` file in the temporary folder. The test now runs a script file in
its own temporary folder, and the package's background pipelines also run
from a script file. Each test file was also run with its own fresh temporary
folder and leaves nothing behind (one test that reached the hardware probe,
and so started 'Python', now mocks it).

## Changes that touch the check

* New imports 'DBI' and 'RSQLite' for a small catalog of document sets,
  runs, model versions, and an append-only event log (including a record of
  each answer and of anything sent off the machine), kept in one SQLite file
  in the user's runs folder (never in the package or home directory unless
  the user points the runs folder there). Tests use temporary folders.
* New suggested packages 'S7' and 'mcptools' for `dragon_ellmer_tools()` and
  `dragon_mcp_server()`, which hand the package's tools to other agents; the
  examples and tests that need them are skipped when they are absent.
* New suggested package 'RPostgres', for an optional shared catalog on
  Postgres; its tests run only when a test server address is given, and are
  skipped otherwise. 'RSQLite' now needs version 2.3.0 or later (SQLite with
  RETURNING).
* New suggested packages 'httpuv' and 'askpass', used only when a person
  connects an outside service from R (a short-lived listener on localhost
  for a browser sign-in, and a masked prompt for a pasted key). Nothing in
  the check or the tests opens a browser or a port to the outside.
* New import 'keyring': the app's Settings page keeps service keys in the
  operating system's keychain, so it is installed with the package. Nothing
  touches the keychain during the check; tests use an in-memory stand-in.
* New file `inst/python/requirements.lock` (about 100 KB): the 'Python'
  packages pinned with hashes. When the package loads, it reads the pinned
  versions from this file to declare them with `reticulate::py_require()`,
  so every machine gets the same versions; nothing is installed and no
  'Python' runs until a user calls a function that needs it.
* New suggested packages 'htmltools', used only by a test that checks
  every input in the app has a label (it is always installed, as 'shiny'
  depends on it), and 'openssl', used to fingerprint exported records
  (without it the fingerprint falls back to MD5).
* New evaluation files under `inst/evals/` (about 30 KB): a question suite
  and two small sets of policy documents with planted instructions, used to
  measure how often a model follows text inside a document. They are read
  only when a user runs that measurement, never during the check.

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
