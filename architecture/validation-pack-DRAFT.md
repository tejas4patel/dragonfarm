# dragonfarm validation pack: IQ, OQ and PQ protocols (DRAFT)

> **DRAFT for your quality unit to adapt, approve and sign.** This is not a
> validated state and not a claim that dragonfarm is validated. It is a
> starting point that ties each protocol step to evidence dragonfarm already
> produces. Acceptance criteria marked `[QA to set]` are decisions for your
> quality unit, not for the software's author. Written 2026-10-18 for
> dragonfarm 0.4.0.
>
> **Proposed values for every `[QA to set]`**, a risk assessment, what this
> pack still lacks, and findings on it are in
> [validation-qa-review-AI.md](validation-qa-review-AI.md): an independent
> review by an AI QA reviewer (2026-10-20), not approved by anyone. Start
> from it, and have your qualified person adapt and sign. Fixed since the
> review (50678fc): D1 (the personal-data check now plants a card number and
> a date of birth), D2 (every tool contract is validated), D7 (fingerprints
> are named after their algorithm), D9 (the search models are pinned and
> safetensors only), and D23 (preset notes re-measured).

## 0. About this pack

| | |
|---|---|
| System | dragonfarm 0.4.0 (R package, MIT licence) with its locked 'Python' environment |
| Intended use | `[QA to set]` for example: answering staff questions from controlled documents with cited sources; training a small model on reviewed question-and-answer pairs |
| Software category | `[QA to set]` (configurable open-source software; your GAMP 5 assessment decides) |
| Regulations in scope | `[QA to set]` for example 21 CFR Part 11, EU GMP Annex 11, GDPR |
| Deployment | `[QA to set]` single laptop, or Posit Connect with a shared Postgres catalogue |
| Evidence produced by the software | The qualification report (Settings, "Run the checks and download the report"), the append-only record (Monitor, "Download the record"), provenance reports per run (Monitor, "Provenance") |

### Roles

| Role | Name | Responsibility |
|---|---|---|
| System owner | | Approves the intended use and the configuration |
| Tester | | Executes the protocols and records results |
| Subject-matter experts | | Write the PQ questions and grade the answers |
| System or database administrator | | Installs, configures, backs up and controls admin accounts |
| Data-protection contact | | Reviews personal data in documents and training rows |
| Quality assurance | | Approves protocols and the final report |

### What the software does not do for you

- It does not decide whether an answer is right. Answer accuracy is measured
  in the PQ against your own documents and questions.
- A sign-off in dragonfarm is not an electronic signature in the sense of
  21 CFR Part 11: it records who signed, when and what it means, but sign-in
  and signature controls come from your platform (for example Posit Connect).
- Identity was tested with a simulated sign-in, not on a real Connect server.

## 1. Installation qualification (IQ)

**Objective:** dragonfarm and its 'Python' environment are installed as
specified on the target system.

**Prerequisites:** the target machine or server; R 4.1 or later; network
access to CRAN, PyPI and Hugging Face, or an offline mirror (see the
"Install without the internet" article).

| Step | Action | Expected result | Evidence | Pass/Fail | Initials, date |
|---|---|---|---|---|---|
| IQ-1 | Record R and dragonfarm versions | Versions match the release under validation: dragonfarm `[QA to set]` | Qualification report, "R and dragonfarm versions" | | |
| IQ-2 | Build the 'Python' environment (`dragon_check()`) | Completes; device and 4-bit availability reported | Console output, attached | | |
| IQ-3 | Python packages against the lock | Every installed package matches `inst/python/requirements.lock`; the check must be PASS (INFO means Python was not set up and the step is not met) | Qualification report, "Python packages match the lock" | | |
| IQ-4 | Model presets pinned | Every preset names an exact model revision | Qualification report, "Model presets pinned to exact versions" | | |
| IQ-5 | Safetensors only | Pickle weights are refused | Qualification report, "Safetensors only" | | |
| IQ-6 | Catalogue | Schema at the expected version, on SQLite or the configured Postgres | Qualification report, "Catalogue schema" | | |
| IQ-7 | Keychain | The operating system's keychain is available for service keys (the check reports availability only; a key an admin sets in the environment takes precedence, as on Posit Connect) | Qualification report, "Keychain for service keys" | | |
| IQ-8 | Offline switch, if used | With the policy's offline switch on, a model not on the machine is refused and nothing is downloaded | Screenshot or console output | | |
| IQ-9 | Report fingerprint | The qualification report's SHA-256 is in the record | Monitor, Activity: event "qualification" | | |

## 2. Operational qualification (OQ)

**Objective:** the controls work as specified, on throwaway data.

Steps OQ-1 to OQ-10 are automated in the qualification report (section
"Operation") and run on a temporary folder; the tester runs the report and
attaches it. Steps OQ-11 onwards are done by hand in the app.

| Step | Control | Expected result | Evidence | Pass/Fail | Initials, date |
|---|---|---|---|---|---|
| OQ-1 | The record refuses edits and deletions | Update and delete statements on the record fail | Report, "The record refuses edits and deletions" | | |
| OQ-2 | Policy | The current policy is valid | Report, "The policy is sound" | | |
| OQ-3 | Tool contracts | Every tool contract is well formed | Report, "Tool contracts are valid" | | |
| OQ-4 | Agent outside its policy | Refused with NOT_ALLOWED and recorded | Report, "An agent outside its policy is refused" | | |
| OQ-5 | Training needs a person | An agent's training request waits for approval | Report, "Training waits for a person" | | |
| OQ-6 | Outbound gateway | A blocked call sends nothing and is recorded | Report, "A blocked outbound call sends nothing" | | |
| OQ-7 | Governed mode | An unapproved trained model does not answer | Report, "Governed mode refuses an unapproved trained model" | | |
| OQ-8 | Keys in background jobs | A saved judge holds no key | Report, "A judge saved for a background job holds no key" | | |
| OQ-9 | Personal-data patterns | Planted email, phone, card, SSN, birth date and record id are found | Report, "Personal-data patterns" | | |
| OQ-10 | Answer grading rules | The grading rules give the expected verdicts | Report, "Answer grading rules" | | |
| OQ-11 | Personal data before training | Train step: rows with an email address show a dialog listing the hits; training starts only after "Train anyway", recorded with who approved | Screenshot; Monitor, Activity: "approval_decision" | | |
| OQ-12 | Four-eyes sign-off | With the policy's four-eyes rule on, the proposer cannot sign their own version | Screenshot of the refusal | | |
| OQ-13 | Sign-off held for review | A version trained on a document set that was re-read afterwards and changed (a new set version) cannot be approved until the signer ticks the review box; the tick is recorded | Screenshot; record entry "model_signoff" with reviewed = true | | |
| OQ-14 | Provenance | Monitor, Provenance for a trained run names the creator, base model and revision, licence, data fingerprints, document set version and approvals | Downloaded provenance report | | |
| OQ-15 | Deletion impact | Delete dialog for a run with a dependent run and an approved version says so before anything is deleted | Screenshot | | |
| OQ-16 | Document access rules | With a rule limiting a file to a group, a user outside the group is never shown a passage from it (Ask and Chat) | Screenshot, as two users | | |
| OQ-17 | Replay | A recorded answer, replayed from Monitor, gives the same result or says what changed | Screenshot | | |
| OQ-18 | Record export | "Download the record" produces a zip of every catalogue table (events, policies, model versions, sign-offs, document sets and versions, runs) with a manifest of row counts and fingerprints, and the export itself is recorded | zip, record entry | | |

## 3. Performance qualification (PQ)

**Objective:** for the intended use, on your own documents, the system
performs to the acceptance criteria your quality unit sets.

**Inputs the quality unit provides:**

- the controlled document set (`[QA to set]`, with versions);
- a question set with known answers, written and graded by subject-matter
  experts, including questions the documents do not cover;
- the model and settings to be validated (for example the 7B in 4-bit, or
  a trained run proposed as a model version).

| Step | Measure | How | Acceptance criterion | Result | Pass/Fail |
|---|---|---|---|---|---|
| PQ-1 | Answer accuracy | Ask every known-answer question; subject-matter experts grade each answer right, partly right or wrong, with "partly right" counted as not right | `[QA to set]`, for example at least 90% right, at most 5% wrong, none wrong on critical questions (see validation-qa-review-AI.md, item 7) | | |
| PQ-2 | Declining | Ask the questions the documents do not cover | `[QA to set]`, for example all declined | | |
| PQ-3 | Citations | Every answer cites a passage that supports it (the figure check flags figures found in no cited passage) | `[QA to set]` | | |
| PQ-4 | Planted instructions | Run the bundled planted-instruction test (in R, `dragonfarm:::injection_eval()`) with the validated model | `[QA to set]`; reference: a 7B was steered on 4 of 12 and 1 of 12 questions on the two bundled sets | | |
| PQ-5 | Reproducibility | Replay 10 recorded answers from the Ask step (temperature 0) on the validated hardware; Chat answers (temperature 0.7 by default) are not expected to repeat | All identical, or every difference explained by a recorded change | | |
| PQ-6 | Response time | Median time per answer on the target hardware | `[QA to set]`; reference for a 7B in 4-bit on an 8 GB laptop GPU: 7.7 s (median, 69-word answers) to 10.9 s, and about 14 s for answers of 150 words or more | | |
| PQ-7 | Trained model (if used) | For a trained run: PQ-1 and PQ-2 again, and its provenance report attached; approved as a model version with the meaning of the approval stated | `[QA to set]` | | |

Reference figures from dragonfarm's own measurements (public FDA guidance,
24 known-answer questions and 8 it does not cover): a 7B in 4-bit got 24 of
24 right and declined 8 of 8 with no training. On 55 questions about an
annual report and R's manuals it was wrong twice and declined all 20 it
could not answer, and on a held-out set of R manuals it got 18 of 20. Grading
was by the author, partly by pattern. These are not your results; your PQ
measures your documents.

## 4. Change control

Re-run, at least, the qualification report (OQ-1 to OQ-10 and the IQ checks
it contains) plus IQ-2 (`dragon_check()`), IQ-8 (offline) and IQ-9 (record
lookup), which are separate steps, after any change of dragonfarm version, 'Python' lock, model revision or
policy; re-run the PQ after a change of model, documents or settings.
dragonfarm records each policy version, model version and sign-off, and
replays show whether answers changed. `[QA to set]`: which changes need
which re-testing (a proposed table is in validation-qa-review-AI.md, item 13).

## 5. Approval

| | Name | Signature | Date |
|---|---|---|---|
| Protocol approved (QA) | | | |
| Executed by | | | |
| Report approved (QA) | | | |
