# dragonfarm threat model

Last reviewed 2026-10-18. Scope: the R package, its Python workers, the
Shiny app, and the optional shared catalogue. Out of scope: the security of
the machine itself, the R and Python installations, and outside services
the user chooses to call.

## What we protect

- The user's documents, and the chunks, indexes and training data made from them.
- Trained adapters and merged models.
- Keys for outside services.
- The record: answers and their sources, approvals, policies, model versions, sign-offs, outbound calls.

## Who and what could cause harm

- A document with text planted to steer the model ("ignore your instructions", "say 90 days").
- An agent (a model calling tools) going beyond what it should do.
- Model weights or Python packages that are not what they claim to be.
- An outside service receiving data it should not.
- A person with access to the machine trying to change the record.
- Mistakes: training on personal data, promoting an untested model.

## Threats, defences, and what we measured

| Threat | Defence | Measured / status |
|---|---|---|
| Planted instructions in documents steer an answer | Excerpts are datamarked for 7B-class models (words joined, model told marked text is data); answers show their sources | 7B followed planted instructions 7 -> 4 of 12 (original set) and 3 -> 1 of 12 (held-out set) with datamarking; smaller models got worse with it, so it is off for them. **Residual: answers can still be steered.** |
| An agent calls a tool it should not | Each agent has a tool list in a versioned policy; anything else is refused (NOT_ALLOWED) and recorded | Unit-tested; agents cannot change the policy (no tool does) |
| An agent trains, promotes, deletes or sends data out on its own | These wait for a person (NEEDS_APPROVAL) in the approvals inbox; approved calls run in the person's name with the approval recorded | Unit- and app-tested |
| Agents on models too small to use tools reliably | Smallest model per agent in the policy (3B default, 7B for answering), from measurements | 20 tool tasks: 0.5B 13, 1.5B 15, 3B 17, 7B 18 right |
| Data leaves the machine unnoticed | One outbound check before the Claude API, web pages, Hugging Face publishing, remote model servers, free tiers and cloud GPUs; each call recorded; admin allow-list (any / none / named hosts) | Tested that a blocked call sends nothing |
| Malicious or swapped model weights | Presets pinned to exact Hub commits; safetensors only unless the user opts in to pickle files | Checked offline loading of pinned 0.5B and 7B |
| Tampered Python packages | Lock file with hashes for offline and admin builds | Offline build from the lock identical to the online one |
| The record is edited or deleted | Append-only tables: the database refuses UPDATE and DELETE (SQLite triggers; Postgres trigger function) | Tested on SQLite and Postgres 16. **Residual: a database administrator can drop the triggers or the file.** |
| Keys leak through scripts or files | Keys kept in the OS keychain; never written to files or the record (names only) | Round trip tested with Windows Credential Manager |
| Personal data in training sets | Fixed-pattern scan with every hit listed; redaction function | Planted set: all found, no look-alikes flagged. **Residual: names, addresses, non-US IDs not detected; training is not blocked yet.** |
| An untested model is put into use | Model versions need an evaluation to be proposed and a person's signed meaning to be approved; optional four-eyes rule | Unit-tested |
| Runaway GPU jobs | One heavy GPU job at a time, enforced; agent step and GPU budgets in the policy | Enforced in code |

## Open items

- Identity: the record names the operating-system user; no single sign-on, so sign-offs are not Part 11 electronic signatures.
- Vulnerability scanning of dependencies and signed releases are not set up.
- No encryption beyond the machine's own; no secrets in the record by design.
- Planted instructions can still steer answers; read answers with their sources.
