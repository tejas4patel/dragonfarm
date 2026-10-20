# OpenSSF Best Practices: self-assessment (passing level)

A working copy of the answers for the OpenSSF Best Practices badge
(<https://www.bestpractices.dev>), with the evidence for each. The project is
registered as <https://www.bestpractices.dev/projects/15710> and earned the
passing badge on 2026-10-20 (all 67 passing criteria answered). "Met" means the evidence below is in this repository today.

Last checked: 2026-10-18.

## Basics

| Criterion | Answer | Evidence |
|---|---|---|
| Description of what the software does | Met | `README.md`, <https://dragonfarm.dev> |
| How to get it, give feedback, contribute | Met | README (install), `CONTRIBUTING.md`, GitHub issues |
| Contribution requirements | Met | `CONTRIBUTING.md` ("Before you send a change") |
| Free/open-source licence | Met | MIT, `LICENSE.md` |
| Licence in a standard place | Met | `LICENSE.md`, `DESCRIPTION` (`License: MIT + file LICENSE`) |
| Basic documentation | Met | pkgdown site: get-started article and articles |
| Reference documentation of the interface | Met | pkgdown reference index (a unit test checks every export is in it) |
| Project sites use HTTPS | Met | <https://dragonfarm.dev>, GitHub |
| Searchable discussion | Met | GitHub issues |
| English documentation | Met | |
| Maintained | Met | Commits this month; `SUPPORT.md` says how |

## Change control

| Criterion | Answer | Evidence |
|---|---|---|
| Public version-controlled repository | Met | <https://github.com/tejas4patel/dragonfarm> |
| Tracks who changed what and when | Met | git |
| Interim versions between releases | Met | `main` branch |
| Unique version numbers | Met | `DESCRIPTION` `Version:` |
| Version tags | Met | git tags `v0.3.0` to `v0.3.4` (0.4.0 not yet tagged) |
| Release notes | Met | `NEWS.md` |
| Release notes name fixed vulnerabilities | Met (none so far) | `NEWS.md` would list them; `SECURITY.md` |

## Reporting

| Criterion | Answer | Evidence |
|---|---|---|
| Bug-report process | Met | GitHub issue forms (`.github/ISSUE_TEMPLATE`) |
| Issue tracker | Met | GitHub issues |
| Acknowledge most bug reports | Met | Best effort, `SUPPORT.md` |
| Enhancement requests answered | Met | Feature form |
| Public archive of reports | Met | GitHub issues |
| Vulnerability-report process | Met | `SECURITY.md` |
| Private vulnerability reports | Met | `SECURITY.md`: email the maintainer; GitHub private reporting needs a repository setting (yours to switch on) |
| Initial response within 14 days | Met (no reports yet) | `SECURITY.md` says "as soon as possible"; consider stating 14 days |

## Quality

| Criterion | Answer | Evidence |
|---|---|---|
| Working build system | Met | `R CMD build` / `R CMD check` |
| Automated build | Met | `.github/workflows/R-CMD-check.yaml` on Linux, macOS, Windows |
| Automated test suite | Met | testthat (about 2,300 expectations), Python tests, integration suite |
| How to run the tests is documented | Met | `CONTRIBUTING.md` ("Running the tests") |
| Tests for new functionality (policy) | Met | `CONTRIBUTING.md` ("Add a test") |
| Evidence that tests are added | Met | Recent commits add tests with each change |
| Compiler warnings / strict checks | Met | `R CMD check --as-cran` in CI, kept free of warnings; notes listed in `cran-comments.md` |

## Security

| Criterion | Answer | Evidence |
|---|---|---|
| Developer knows secure design | Met | `architecture/threat-model.md` |
| Uses vetted cryptography, no home-made crypto | N/A | No cryptography is implemented here; keys go to the OS keychain through `keyring` |
| Delivered over a channel safe from tampering | Met | CRAN and GitHub over HTTPS; Python packages locked with hashes (`inst/python/requirements.lock`) |
| No known unfixed vulnerabilities older than 60 days | Met | None known |
| No leaked private credentials in the repository | Met | `CONTRIBUTING.md` forbids them; keys read from the environment or keychain |

## Analysis

| Criterion | Answer | Evidence |
|---|---|---|
| Static analysis before release | Met | `.lintr` correctness checks in CI (`.github/workflows/lint.yaml`); R CMD check's codetools |
| Static-analysis findings fixed | Met | 0 lints at the time of writing |
| Dynamic analysis (suggested) | Partly | Unit, integration and headless-browser tests (`scripts/ui_walkthrough.R`, `scripts/a11y_states.R`); no fuzzing |
| Memory-safe language | Met | R and Python |

## Open items

1. Done 2026-10-20: answers entered at bestpractices.dev (project 15710), passing badge earned.
2. Turn on GitHub private vulnerability reporting (a repository setting).
3. Optionally state a 14-day first response in `SECURITY.md`.
4. Tag 0.4.0 when it is released.
