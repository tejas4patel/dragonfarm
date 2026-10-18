# dragonfarm 0.4.0

The headline of this release is a document route: drop in PDFs, Word files,
web pages, or spreadsheets, ask questions with cited sources, have a model
write training questions from them, review those, and fine-tune. The app now
opens on it, has a new look with a dark mode, and can train a 7B model in
4-bit on an 8 GB GPU. Everything below was measured on an 8 GB laptop GPU
(RTX 4060) and on real documents: R's own manuals, a 76-page annual report as
PDF and as Word, live web pages, and a spreadsheet.

## Documents

* Numbered headings in PDFs ("6.4 Updating packages") start their section
  even when the line before them was a long one that ended a sentence;
  they used to be glued on to the end of the previous paragraph, so the
  section was never started and search could not find it (26 such headings
  in R's installation and data manuals, 29 in An Introduction to R). With
  R's two installation and data manuals as a held-out test, the answer
  reached the top four excerpts for 19 of 20 questions (from 17) and a 7B
  answered 18 (from 16); on R's introduction and FAQ, 32 of 32 (from 31).

* PDF lists printed one entry per line, such as an annual report's
  "CALIFORNIA – 140" location counts, keep their entries apart ("; ")
  instead of running together, and no-break spaces become plain spaces. Asked
  for eight places' counts, a 7B read 7 right against 4 with the run-on
  text; the report's California count, missed before, is now answered (21
  of 23 known-answer questions, from 20).

* New: `dragon_documents()` reads PDF, HTML, Markdown, text, Word,
  spreadsheet files, directories of them, and web pages into a *document
  set*: chunks of about 170 words that never cross a heading, each keeping
  its file, section, and (for PDFs) page, stored under
  `runs_dir/documents/<name>/`. Reading again re-reads only files whose
  contents changed, and a set built by an older version of the readers is
  re-read rather than reused. `dragon_chunks()` (with a `page` column),
  `dragon_documents_load()`, and `dragon_documents_list()` go with it. The
  Python environment gains `pypdf` (with `cryptography`, for encrypted
  PDFs), `python-docx`, and `openpyxl`.
* `dragon_example_documents()`: three short policy documents for the
  fictional company behind the example tickets, so the route can be tried
  before bringing your own files.
* PDFs. Pages whose text comes out of the standard extractor as two-letter
  fragments (`Co st co Wh ol es al e`, common in annual reports) are re-read
  in a layout-aware mode: a 76-page annual report went from 726 unreadable
  chunks to 273 readable ones under real section names. Running headers,
  page numbers, contents entries with dot leaders, and dot leaders inside
  table rows are dropped; a sentence broken across pages is rejoined; code,
  lead-in lines, rows of numbers, and single words are no longer taken for
  headings (R-intro went from 97 section names, one 1,489 characters long, to
  79 real ones); apostrophes a font did not map are restored. A PDF with no
  text layer (a scan) is reported by name with advice to run OCR first,
  instead of silently adding nothing.
* Year columns. In a financial table the years are printed once, above the
  figures; flattened into text, nothing said which figure was which year, and
  answers came from the wrong column. Rows under a year header that end in
  one figure per year now carry the years: "Net cash used in investing
  activities (2024: (4,409); 2023: (4,972); 2022: (3,915))". On ten questions
  about an annual report that need a specific year's figure, correct answers
  went from 5 to 9, and confident wrong-column answers from 2 to none. Word
  tables get the same treatment from a header row of dates, and their merged
  cells are no longer repeated once per column they span ("249,625 |
  249,625"); the Word copy of the report went from 8 to 10 of 10.
* Units. A note such as "(dollars in millions, except per share data)" is
  carried into later chunks that show money without a unit word, so answers
  from financial tables say "$4,409 million" rather than "$4,409".
* Word. Unit notes styled as headings set the unit instead of becoming a
  section; short paragraphs set entirely in bold or italic become headings
  when prose follows them (the sub-headings of a 10-K are italic), while table
  column labels, which look the same, stay text. The Word annual report went
  from one 38-chunk "Note 1" to 123 real sections.
* Web pages. Blocks made mostly of links and regions marked as navigation,
  banner, footer, or search are dropped, so a page without a `<nav>` tag no
  longer leaks its menu into the first chunk. Heading anchor glyphs (the
  pilcrow after every R FAQ heading) are removed.
* Spreadsheets. Each row becomes "column: value" pairs; a two-column
  label-and-value sheet is read as such rather than as a header plus data; a
  first row of numbers is not taken for column names; and each sheet starts
  its own chunk.
* A manual or FAQ with numbered sections ("2.1 What is R?") is no longer
  mistaken for a changelog; changelog-like files are still flagged and
  down-weighted, and quoted material and code blocks are marked on each chunk.

* PDFs with outline headings ("I. INTRODUCTION", "A. General
  Considerations", "III. ESTIMANDS (A.3)"), as in FDA and ICH guidances, now
  get their real sections, and a street address on a cover page is never
  taken for a heading. Before, the agency's mailing address labelled 48 of
  153 chunks of four FDA guidances. Top-1 retrieval on 18 questions about
  them rose from 44% to 67% (dense search) and from 61% to 72% (hybrid). Other
  PDFs read exactly as before. Document sets are re-read on next use (reader
  version 19).

* A short PDF (a one-line notice) is read instead of being called scanned;
  only a PDF with no text at all, or a few words over pictures of pages, is
  reported as scanned. When every file is a scan, `dragon_documents()` says so
  and suggests OCR, instead of listing the supported formats.

* Reading a folder now says which files it skipped because no reader handles
  them, in one line grouped by type, with what to save them as ("Skipped 2
  files dragonfarm can't read: 1 .doc (save it as .docx), 1 .pptx (export it
  to PDF)."). Before, they were left out silently.

* Encrypted PDFs that open without a password (common for official
  documents) are read; before, AES-encrypted ones failed with "cryptography
  is required". A PDF that needs a password says so in plain words. Text,
  CSV, and HTML files saved in Windows-1252 or UTF-16 read cleanly instead of
  with replacement marks for every accented letter. Files in `.doc`, `.xls`,
  `.pptx` and similar formats are refused with what to save them as. Saved
  sets read identically (reader version 19).

## Setup

* The Python environment dragonfarm builds for itself now uses the exact
  versions in its lock (every package, for each platform), so every machine
  gets the same versions and none drift as new releases appear. Built and
  checked on Windows with the CUDA build of torch: every installed package
  matches the lock. `DRAGONFARM_PYTHON_LOCKED=false` asks for the newest
  releases instead.

* Training waits for a person when its rows hold likely personal data
  (email addresses, phone numbers, US social security and card numbers,
  labelled dates of birth and record ids). The app's Train step lists the
  hits and starts only after "Train anyway", which is recorded; the
  `train_model` tool refuses with `PERSONAL_DATA` until called with
  `allow_personal_data`; `dragon_train()` warns. On the FDA guidance set,
  15 of 442 rows hit, all of them FDA's public contact lines; an admin can
  list such public contacts in Settings ("*@fda.hhs.gov, 301-796-3400"),
  and with FDA's listed the same set has none.

* Every run now records who created it and from what. A run trained on
  questions from a document set remembers the set and its version, and a
  "Train anyway" approval for personal data travels with the run. Monitor's
  "Provenance" download gives the whole story of the selected run: who
  started it and when, the base model, its revision and licence, the
  training data with fingerprints, the document set version (and whether
  the set has been re-read since), the approval, the evaluation and any
  sign-offs. Deleting a run first says what depends on it: runs that
  continue from it and model versions, with approved ones called out.
  Agents can ask the same through three read-only tools: `check_licence`,
  `provenance_report` and `deletion_impact`.

* Before a model version is signed off, Monitor lists what the record says
  is worth reading first: a licence with terms of its own, training rows
  with personal data (and who approved them, or that nobody did), a
  document set re-read since training, remote code, or no evaluation. The
  list is kept with the signature. Two of them hold an approval until the
  signer ticks that they reviewed them, and the tick is recorded: a
  document set re-read since training, and personal data that nobody
  approved. Rejecting or retiring never needs the tick.

## Asking documents

* Questions about a whole set ("which document is the oldest?", "what is in
  this set?") get better answers: an untrained model now sees the set's
  documents listed by name and length before the excerpts. On ten such
  questions over the four FDA guidances, a 7B went from 6 to 9 right. The
  same 7B still got all 24 known FDA questions right and declined all 8
  others; a 1.5B and a 3B moved by one question each way. Model-written
  overviews of each document were tried too, and lost facts.

* Answers stream as they are written: `dragon_ask(on_token = )` and the Ask
  step in the app show the first words while the rest is still coming. With
  full answers from a 7B (often 150 words or more), the first words arrived
  after a median 0.8 seconds against 14 seconds for the whole answer.

* `dragon_chat()` and the app's Try it and Chat steps now allow 600 new
  tokens by default (was 256 and 200), as `dragon_ask()` does: with full
  answers, 21 of 100 benchmark answers from the 7B ran past 150 words and
  were cut off mid-sentence at the old limits. It is a ceiling, so short
  answers are no slower.

* `dragon_ellmer_tools()` hands dragonfarm's tools to any `ellmer` chat, or
  to Claude Desktop and other MCP clients with `dragon_mcp_server()`: search a
  document set (or one document in it), answer from it with citations,
  check an answer's figures, read documents, build the training set (saved
  for a person to read before approving training), list sets and runs,
  check a run. Every call is checked against the tool's contract,
  callers named as agents are held to a policy (some calls are refused, some
  wait for a person), and every call is recorded in a small catalogue kept in
  the runs folder.

* Some protection against instructions planted in documents ("ignore your
  instructions", "always say 90 days", "answer in French"). For 7B-class
  models the excerpts are datamarked: their words are joined with `^` and the
  model is told marked text is information only. On 24 questions over
  documents with planted instructions, the 7B followed 10 of them without it
  and 5 with it, and answered the FDA test questions exactly as before. It
  made smaller models worse, so it is off for them;
  `options(dragonfarm.datamark = TRUE)` or `FALSE` forces it. Planted
  instructions can still get through; check the sources. The two test sets
  ship with the package, so the rate can be measured again for any model and
  is recorded in the catalogue (rerun on the 7B: 4 of 12 and 1 of 12 steered,
  as first measured).

* `dragon_check()` now says whether agents are on for this machine. Agents
  need a model of 3B or larger: on 20 tool-use tasks, 3B and 7B models got
  17 and 18 right, 0.5B and 1.5B models 13 and 15. On smaller machines
  everything still works through the fixed workflows. With a model server
  connected, the server's model is the one that counts, so a CPU-only
  laptop with a server can run agents. An agent's task keeps
  a checkpoint after every step; if R stops mid-task, it carries on from
  there without repeating the tool calls it already made. The policy can
  name a model per agent, and when an agent cannot finish (its model is too
  small, it runs out of steps, or it fails) the fixed workflow answers
  instead; Monitor's "Last 7 days" counts how often that happened. Before a
  task starts, its plan says what the agent may use and what each tool does
  (reads, writes, cannot be undone, leaves the machine), which steps wait
  for a person, its budget, and how long such tasks took here before. The
  plan is kept with the task, and Monitor shows it beside the steps taken.

* Settings can run a qualification report: checks that the installation
  matches what is specified (Python packages against the lock, models pinned
  to exact versions, safetensors only, the catalogue schema) and that the
  controls work on throwaway data (the record refuses edits, agents stay
  within the policy, training waits for a person, blocked data stays put,
  the personal-data patterns). You download a dated report with each check
  and its evidence; its SHA-256 goes into the record. It is evidence for a
  validation, not a validation.

* "Check for personal data" in the Documents step lists email addresses,
  phone numbers, US social security numbers, card numbers, and labelled
  dates of birth and patient or record ids found in a set, each with where
  it was found, by fixed patterns (no model). Every hit is shown for a person
  to judge: contact lines of organisations are common in public documents.
  On the documents tested here it flagged only such contact lines and no
  numbers, versions or dates by mistake.

* The policy can be changed in the app: Settings has a Policy card for the
  tools each agent may use, what waits for a person, where data may go, the
  four-eyes rule for model sign-off, and agent budgets. Each save is a new
  version with who changed it and why; older versions stay listed. With
  `options(dragonfarm.admin = FALSE)` the card is read-only.

* A team can share one catalogue on Postgres: set `DRAGONFARM_CATALOG` to a
  `postgresql://` address (or `options(dragonfarm.catalog =)` to a function
  that returns a DBI connection) and every runs folder records its events,
  approvals, policies and model versions there, append-only as on a laptop.
  Without it, nothing changes: each runs folder keeps its own SQLite file.

* On a server that signs people in, such as Posit Connect, the record,
  proposals, sign-offs and policy changes name the signed-in person, not the
  server's account. The policy can name admins and admin groups; then only
  they may change it. Access rules in the policy can limit documents to
  groups ("hr-*.pdf" for HR only): a person outside them never receives a
  passage from those documents, in search, answers, chat or the set's
  listing. Admins, admin groups and access rules are set in the policy card
  in Settings, which refuses a change that would leave its author without
  admin rights. Tested with a simulated sign-in, not yet on a real Connect server.

* Governed mode: an admin can tick "Only approved model versions answer
  questions" in Settings. Then a trained run answers in Ask, Chat and the
  answer tool only once a person has approved it as a model version in
  Monitor; until then it is refused with NOT_APPROVED before anything runs.
  Untrained models, Try it and evaluation are not affected, so a candidate
  can still be checked before it is approved. On a server (Posit Connect, or
  a shared Postgres catalogue) governed mode and the four-eyes sign-off are
  on by default; on a single laptop they are off. A choice saved in Settings
  always wins.

* More of the record-keeping is in the app, not just in R: Monitor has a
  "Model versions" card (propose a finished, evaluated run as a version of a
  named model, then approve, reject or retire it with a stated meaning), and
  "Run it again and compare" on recorded calls and answers in Activity (8
  answers a 3B gave on the FDA guidance replayed identically: the same
  excerpts, prompt and answer; when they differ it says whether the set was
  re-read, the model changed, or other excerpts were found), and "Download the
  record (CSV)" for an auditor (the export itself is recorded with a SHA-256
  of the file). Activity opens with a "Last 7 days" line: what happened,
  what was refused or failed, what left the machine and to where, and how
  many approvals are waiting. A run that says it is running but has not
  moved for a long time (15 minutes, or five of its usual gaps between
  progress lines) gets a plain warning: a laptop that sleeps stalls GPU jobs
  that way. An agent task in Activity opens to its steps
  (each tool call, its result and time, and the model's time), and the last
  week can be downloaded as OpenTelemetry traces for a company's monitoring
  tools, with no extra packages. The Documents step
  has "Check it re-reads the same", which reads a set's files again and says
  whether they come back identical.

* Answers in the Documents step get a quick check that needs no model:
  every figure in the answer (numbers, dates, percentages, versions) must
  appear in its excerpts or the question, and every citation must point at
  an excerpt. A plain line appears only when something is off ("Check this:
  4.0 is not in the excerpts."). On 224 recorded answers from 1.5B and 3B
  models it flagged one, a real wrong figure, with no false alarms, and it
  caught 37 of 37 figures changed by hand. It cannot catch a real figure
  used wrongly, or wrong words: 10 of 11 wrong answers there had no figure
  to check. ellmer chats and MCP clients get it as the `check_answer` tool.

* Chat counts your thumbs up, thumbs down and edits, and "Train on my
  feedback" turns the liked and edited replies (with the turns before them)
  into a training set, ready in Train. Before, this needed
  `dragon_feedback()` in R.

* The Map step can let a stronger model write the replies to your prompts
  ("Let a stronger model write the replies"): by default the best model for
  this machine, or Claude, OpenRouter or Groq when you pick one (the choice
  is recorded, and every request passes the outbound check). It runs in the
  background, and the new prompt-and-reply set loads for review and
  training. Before, this needed `dragon_synthesize()` in R.

* The Data step loads chat-format JSONL (a `messages` list per row, the
  format Chat exports) as whole conversations, ready to train without a
  Map step. Before, multi-turn training needed `dragon_conversations()`.

* The app passes an automated WCAG 2.1 A/AA check (axe-core 4.10.2) on
  every tab, in light and dark mode; before, it flagged 68 places under 5
  rules. The page declares its language, the hardware badge and dark-mode
  switch sit outside the tab list, warning and success text are dark enough
  to read, and every text box and drop-down has a label for screen readers.
  The same check also passes on what appears after you act: a reply beside
  the base model's, a judge's verdict, a chat with its feedback buttons, an
  answer with its sources, and the review of written questions. Contrast
  the checker cannot judge was measured by hand; that found the faint note
  under each answer at 4.29:1, below the 4.5:1 needed, and it is now darker,
  as is placeholder text in boxes.

* The app has a Settings page for the keys of outside services (Hugging
  Face, the Claude API, Kaggle, Lightning AI, OpenRouter, Groq): paste a key
  once, and it is checked and kept in the computer's own keychain (through
  the 'keyring' package), never in scripts or files. Kaggle's downloaded
  kaggle.json is picked up from Downloads with one click. Free tiers are
  turned on there too, with a daily cap. Messages that used to say "set
  HF_TOKEN in the R session" now point to Settings.

* An offline switch in the Settings policy card stops every model download:
  models must already be on the machine, and a missing one fails at once
  instead of downloading. It is separate from "where data may go: nowhere",
  which leaves downloads alone because they send none of your data.

* `dragon_backend_server()` gains `api_key_env`, the name of the environment
  variable that holds the key; the key is read each time a request is sent
  and never stored in the backend object. With no key given, it now keeps
  the name `DRAGONFARM_API_KEY` (or `OPENAI_API_KEY`) rather than copying
  the key, so a backend saved with a background job holds no key. A key
  passed as `api_key` still works, with a warning once per session.

* Try it's judge can be a free-tier model (OpenRouter or Groq) as well as
  Claude or a local model, once its key and opt-in are set in Settings.
  A judge running in the background looks its key up when it is called, so
  the key is never saved with the job; a test checks that saved judges and
  teachers contain no key.

* Training on a free cloud GPU from the app takes fewer steps. One button
  packs the run, saves it to your Downloads folder and opens the notebook,
  which now asks Colab and Kaggle for a GPU by itself. In Colab you press
  Run all and pick the file; when the results land in Downloads, the app
  imports them. The steps the app shows no longer include any code. With a
  Kaggle key (kaggle.json), Kaggle needs no clicks at all: the app uploads
  the run as a private dataset, starts the notebook on a GPU, waits, and
  imports the results, showing where it is as it goes. Lightning AI works
  the same way with your Lightning keys: the app starts a GPU Studio,
  trains, brings the results back and stops the Studio, even if something
  fails.

* Every answer from documents (`dragon_ask()`, the Ask step, and chats with
  documents) is recorded in the runs folder's catalogue with what it came
  from: the exact chunks (checksum) and reader, the model and its pinned
  revision, the settings, every excerpt shown to the model and whether it
  was cited, and the answer. The answer's `$trace` holds the record's
  number; in the Monitor tab's Activity card it opens as a readable trace:
  the question, the answer, the model, the set's version, and the excerpts
  behind it with their text (while the set is unchanged).

* Everything that sends data off the machine (the Claude API, fetching web
  pages as documents, publishing to Hugging Face, a model server elsewhere,
  free tiers, cloud GPUs, and checking a saved key)
  now passes one check and is recorded in the runs folder's catalogue with
  where it went and why. An admin can limit the hosts in the policy, down to
  none at all.

* For servers and machines without the internet, the package ships a lock
  of its Python packages (`inst/python/requirements.lock`, pinned with
  hashes, all platforms, from PyPI) and a new article, "Install without the
  internet". An environment built from it offline, with an empty cache, was
  identical to one built online. With `DRAGONFARM_PYTHON` set,
  `dragon_check()` says whether the environment matches the lock.

* `dragon_resume()` after a crash is sturdier. A checkpoint cut short by the
  crash is skipped for the one before it; the run's log keeps what came
  before the crash (it used to be replaced); steps trained again are no
  longer drawn twice in the loss chart; a run that crashed before its first
  checkpoint starts again instead of failing. GRPO runs now resume with
  their adapter weights and optimizer state (they used to resume the step
  count only, from fresh weights). Checked by killing runs mid-way: a resumed
  135M fine-tune ended at eval loss 1.188, against 1.189 for the same run
  without a crash.

* `dragon_ask(compare = TRUE)`, and "Look for documents that disagree" in the
  app's Ask step, help when documents give different versions of the same
  rule. The usual top excerpts stay; two more are added that are relevant but
  say something different (a rule repeated by many documents otherwise
  crowds out the one later document that changed it), and the model is asked
  to give each document's version. On a test set of six such rules, both
  versions reached the model 6 of 6 times instead of 3 or 4, and a 7B named
  both in 13 of 24 answers instead of 6. It still sometimes calls differing
  documents consistent, so check the sources. `dragon_retrieve(extra = )`
  exposes the extra excerpts on their own.

* Chat with documents understands short follow-ups. "And a boxplot?" or
  "Which ones, then?" names nothing to search for, so such a turn (ten words
  or fewer, leaning on the last one with "it", "those", "what about" and the
  like) keeps its own best two excerpts and fills the rest from a search
  with the previous question in front. On 22 follow-ups about the FDA
  guidances and R's manuals the right excerpt came back for 19 instead of
  16; 12 changes of topic and 57 longer follow-ups were unaffected.

* Full answers from documents: `dragon_ask()` and chat with documents ask
  models of 3B and up for complete answers with the figures, steps, or code
  the excerpts hold, instead of one short sentence. On 75 questions with
  known answers the 7B now gets all 75 right (was 72) and the 3B 70 (was 65),
  still declining all 25 the documents do not cover; answers are longer (a
  median of 60 words for the 7B) and take about twice as long. Smaller
  models keep the short instructions, since full answers made them invent
  more. `max_new_tokens` now defaults to 600.

* Untrained models under 3B get one more line in their instructions when
  answering from documents: "If no excerpt states the answer, reply only:
  'The documents do not cover this.'" Over 55 answerable and 20 unanswerable
  questions, wrong or made-up answers fell from 33 to 25 (0.5B) and from 21
  to 10 (1.5B, the default on CPUs and small GPUs, which now declines all 20
  unanswerable questions). The same line made a 3B refuse questions it could
  answer (8 to 18 bad answers) and did nothing for a 7B, so larger and
  fine-tuned models do not get it.

* With four or more excerpts, the keyword search's best match is always
  among them, as the embedding's best already was. A rare exact word
  ("boxplot") put its chunk first by keywords but far down by embedding, and
  the combined ranking dropped it. Questions about R's manuals with the
  answer in the top four: 30 to 31 of 32; a 7B answered all 23 known-answer
  questions on the annual report PDF (from 22). Other sets unchanged.

* A question that names a year now finds the table row labelled with that
  year. Rows read as "Net sales (2024: $249,625; 2023: $237,710)" carry a
  keyword per labelled year, which a question mentioning 2023 searches for;
  a bare "2023" appears all over a report and did little. Known-answer
  questions on the annual report reaching the top four excerpts: PDF 85 to
  95 percent, Word 85 to 100 percent, other sets unchanged. A 7B answered
  22 of 23 on the PDF (from 21) and stayed at 23 of 23 on the Word copy.

* New: `dragon_index()` embeds a document set with a small encoder
  (`BAAI/bge-small-en-v1.5`, kept warm in the inference worker),
  `dragon_retrieve()` returns the most relevant chunks, and `dragon_ask()`
  puts them in front of a model as numbered excerpts and returns the answer
  with its sources, marking which were cited: "report.pdf, p. 68 › Item 14".
  The model defaults to the one `dragon_check()` recommends for the GPU and
  can be any run, model id, or server backend. `dragon_chat()` gains
  `documents` and `k`; `$sources()` shows the excerpts behind the last reply.
* Retrieval is hybrid by default: the embedding ranking is combined with a
  keyword (`BM25`) ranking over each chunk's section title and text,
  counting only chunks that share a word with the question, and the
  embedding's own best match always stays among the excerpts. Exact terms
  and figures that a small embedding model ranks a few places too low still
  reach the answer. The share of questions whose source chunk was among the
  four excerpts, embedding alone against hybrid: R's manuals 90.7 to 94.5
  percent (616 questions), the package documentation 88 to 100, a
  spreadsheet 83 to 100; on an annual report the right chunk is ranked first
  for 75 to 83 percent of questions, up from 58 to 67.
  `dragon_retrieve(method = "dense")` keeps the embedding ranking alone, and
  `scripts/retrieval_eval.py` measures both on any indexed sets.
* On the annual report the default 7B in 4-bit answers 20 to 23 of 23
  factual questions with known answers (Word copy 23, PDF 20 to 21),
  including ten that need a specific year's figure from a table. The PDF
  misses a total printed inside a map graphic, and the model says so rather
  than guessing. Six excerpts instead of four did not help.

## From documents to training data

* `dragon_questions(mix = TRUE)`, the new default, asks for a mix of
  question types per chunk: a "what" or "which", a "why" or "how", and,
  where the passage compares two things, a "how do they differ". On four
  FDA guidances comparison questions rose from 11 to 98 of the kept pairs
  and why/how questions from 113 to 142; 81 percent of pairs were kept
  instead of 89, and a 3B trained on either set answered the same 23 of 24
  test questions. `mix = FALSE` asks for any three questions, as before.

* `dragon_questions_dataset()` adds "not covered" rows by default
  (`negatives = 0.15`): a question shown with excerpts from another section,
  answered "The documents do not cover this." Without them every training
  prompt contains its answer and tuned models answer everything. On R's
  manuals, a tuned 0.5B, 1.5B, and 3B declined 0, 1, and 5 of 15 questions
  the manuals do not cover; with negatives all three declined 15 of 15,
  while answerable questions went from 24 to 26, 29 to 28, and 30 to 30 of
  32. Wrong, made-up, or wrongly declined answers over all 47 questions fell
  from 23 to 6 (0.5B), 17 to 4 (1.5B), and 12 to 2 (3B). (Measured with
  this release's reading and search, both sides.)

* New: `dragon_questions()` has a model write questions and answers from each
  chunk (the local model recommended for the machine, in the background, or
  a teacher such as `dragon_llm_anthropic()`), runs deterministic filters,
  and returns every pair with `keep` and a `reason`. With the default 7B,
  78 to 87 percent of pairs passed on real documents; a small generator does
  far worse, so review is part of the workflow. A batch that runs out of GPU
  memory is retried one chunk at a time, and long passages are capped.
  `dragon_questions_save()` records your decisions.
* `dragon_questions_dataset()` builds the training set with retrieved
  excerpts in front of each question, always including the chunk the pair
  was written from, and appends that excerpt's number to the answer
  (`cite = TRUE`) so a tuned model keeps citing. It warns if the document
  set was re-read after the questions were written.

## The app

* The app opens from RStudio's Addins menu ("dragonfarm"), no code needed.

* Monitor says how much room runs take, warns about a run that has stopped
  moving, and points at the biggest saving: the checkpoints of finished
  runs, which are only used to resume a run that stopped. On one laptop
  they were 14 of 18 GB. "Remove them" lists the runs and frees the space
  only after you confirm; each run keeps its trained adapter, and the
  removal is recorded.

* Every model choice in the app has an (i) icon: hovering over it, or
  focusing it with the keyboard, shows how the four model sizes compare on
  that task, as measured for the "Choosing a model size" article. Answering
  ("Answered by" in Ask, the run in Chat): wrong answers, "not covered"
  replies, and speed. Writing questions ("Written by" in Teach): pairs kept
  and how many were correct. Training (the Model step and Try it):
  results after fine-tuning, training time, and GPU memory.

* The app starts with documents. A new **Documents** tab is tab 1: drop
  files or add web pages, read and index, ask with sources, continue in Chat.
  Its **Teach** card generates questions in the background, shows the yield
  as it grows, and lets you tick and untick pairs grouped by chunk before
  Continue to Model, which skips Data and Map. The table route (Data and Map
  first) is one link away or `dragon_app(route = "table")`.
* Panels take their natural height and the page scrolls; the Map step's
  drop slots and the Try it cards are no longer clipped. A message now says
  to wait for "Upload complete" when Read and index is pressed while a large
  file is still uploading.
* A new look that matches dragonfarm.dev: a dark navbar whose tabs read as
  numbered steps, a one-line introduction on each step, the website's fonts
  and amber-to-coral accents, model presets as selectable cards with size,
  memory, and licence, a loss chart in the same colours, and a dark mode
  switch in the navbar.
* The Training step can load the model in 4-bit (QLoRA), so a 7B trains from
  the app on an 8 GB NVIDIA card. The box ticks itself, with gradient
  checkpointing, when the chosen model's full-precision weights would crowd
  the GPU (a 3B or 7B on 8 GB), sets batch size 1 with gradient
  accumulation raised to keep the effective batch, and says so when there is
  no NVIDIA GPU.

## Hardware and models

* `dragon_presets()` adds Qwen 2.5 3B and 7B, both trained in 4-bit (a 3B
  peaks at 4.3 GB on 1,536-token document prompts, a 7B at 7.9 GB), and its
  notes now say which task each size suits. A new `load_in_4bit` column says
  which presets need 4-bit to fit. On the documents route the app's Model
  step starts from the model the hardware check recommends (a 7B at 8 GB,
  a 3B at 6 GB) and warns when a model under 3B is chosen for documents.
  The measurements behind this are in a new article, "Choosing a model size".

* Training computes its loss through the output layer in chunks, so the
  scores for the whole vocabulary are never held at every position at once.
  With a 151,000-token vocabulary that tensor was about a gigabyte per row
  at 1,536 tokens. Training a 0.5B on 616 document pairs at 1,536 tokens ran
  out of memory on an 8 GB card; it now peaks at 6.2 GB and takes 8
  minutes, where turning on gradient checkpointing to make it fit took 29.
  The loss and its gradients are identical to the model's own (tested).
  It is used only for batches whose full scores would exceed 256 MB
  (`DRAGONFARM_CHUNKED_LOSS_MB`); shorter batches keep the original path,
  which kept a 7B in 4-bit on short rows at 13 seconds a step where always
  chunking took 54. `DRAGONFARM_FULL_LOSS` turns it off entirely. With it,
  a 7B in 4-bit trains on 1,536-token document prompts on an 8 GB card (616
  pairs, three epochs, 4.3 hours); the tuned 7B matched the untrained one on
  accuracy and always cited its excerpt.
* 4-bit loading for generation, on Windows as well as Linux.
  `dragon_backend_local(load_in_4bit = "auto")` quantizes a model to NF4 only
  when its full weights would not fit the GPU, so a 7B runs on an 8 GB card
  (about 5.5 GB of weights) while a 3B still loads in full precision.
  `dragon_check()` reports whether 4-bit loading is available and which model
  it would use: a 1.5B under 6 GB, a 3B at 6 to 8 GB, a 7B in 4-bit at 8 GB
  and up. QLoRA training (`dragon_hardware(load_in_4bit = TRUE)`) works on
  Windows: three epochs of Qwen2.5-7B-Instruct on the 190 example tickets
  took 22 minutes on the 8 GB card, peaked at 7.9 GB, and reproduced the
  example policies on held-out tickets where the 0.5B had drifted.
* `dragon_check()` reports GPU memory already held by other programs and
  lists dragonfarm processes started by other R sessions; training warns
  about them, and `dragon_worker_stop(all = TRUE)` stops them.
* Generating for several prompts at once runs them in batches of eight:
  eight short prompts through a 0.5B went from 17 to 37 seconds to 6.

## Name and look

* A dragon of its own: a new hex logo, favicon, and app icon with an
  original dragon, the slogan "Raise your own dragon", and a lighter voice
  in the app's step headings and on the website. Model cards in the app show
  a life stage (Egg, Hatchling, Drake, Wyvern, Elder) beside the size.
  Function names and error messages are unchanged.

* Replies in the app are shown as formatted text: lists, bold, and code
  blocks render instead of raw Markdown. Nothing a model writes can add its
  own markup: raw HTML is escaped, links other than http(s) and mailto are
  neutralised, and images are dropped.

* The GitHub repository is now `tejas4patel/dragonfarm`, matching the
  package name: `pak::pak("tejas4patel/dragonfarm")`. Old
  `tejas4patel/dragon-farm` links keep working through GitHub's redirect.

## Fixes

* `dragon_serve_ollama()` finds Ollama in its usual install folder when R
  was started before Ollama was installed, and checks that Ollama can
  actually answer with the model it registered. With Ollama 0.40.5 on
  Windows, safetensors import goes through Ollama's MLX engine, which
  refused a Qwen run and could not run a SmolLM2 one; the error now says so
  plainly, removes any unusable copy, and points to a GGUF file from
  `dragon_export_gguf()` instead. Other systems were not tested.

* Training, writing practice questions, evaluating, and merging now refuse
  to start while another of them is running on the GPU (in any R session),
  saying which job is in the way. Two at once on an 8 GB card fail in ways
  that look like bugs. `options(dragonfarm.allow_parallel_gpu = TRUE)` turns
  the check off.

* Practice questions from models that wrap their labels in Markdown
  (`**Q1:**`) are no longer thrown away: a 1.5B wrote every label in bold
  and none of its 22 pairs were kept; now all 22 parse. Every earlier
  question set re-parses identically (3,362 pairs).

* Preset models are pinned to the Hub commit they were tested with, and runs
  record it, so a run trains and answers with exactly those weights even if
  the model's page changes later. Models load from safetensors only: weights
  that exist only in the older pickle (`.bin`) format can run code when
  loaded and are refused with a plain message, unless you set
  `options(dragonfarm.allow_pickle_weights = TRUE)` for a model you trust.

* A model id with a typo ("Qwen/Qwen2.5-0.5B-Instruc") now says there is no
  such model and suggests the closest preset, instead of passing on a
  message about private repositories and tokens.

* The Monitor shows "Cancel run" only while a run is queued or running, and
  "Resume from checkpoint" only after it failed or was cancelled; both used
  to show for every run, finished ones included.

* `dragon_ask()` asks once more, in the same conversation, when a model
  replies with nothing but a citation marker such as "[1]". The 3B did this
  on 6 of 65 benchmark questions; with the retry it left none empty and
  answered 28 of 32 questions about R's manuals instead of 24. Chat with
  documents (`dragon_chat(documents = )` and the app's Chat tab) does the same.
  If the second reply is only a marker too, a third, plain attempt gets just
  the cited excerpt and the question; on 100 benchmark questions the 1.5B
  was left with a bare "[2]" twice and now with none (one of the two now
  right). An answer written in brackets, like "[R_LIBS_USER]", is no longer
  mistaken for a citation.

* The app no longer slows to a crawl with many runs. Seven panels each
  listed every file under the runs folder every three seconds, checkpoints
  and indexes included; with a thousand files that took about a second a
  time and kept the app busy. They now look two levels deep (7.5 times
  faster here). The Monitor also stopped resetting a run you had just
  picked back to the newest one when the run list refreshed.

* A training run that runs out of GPU memory now says so, with the usual
  fixes, including when the error arrives as `CUBLAS_STATUS_EXECUTION_FAILED`
  (a 7B in 4-bit at batch size 4 on an 8 GB card) rather than "out of memory".

* A background pipeline that was cancelled or stopped left an `Rscript*`
  file in the temporary folder on Windows, because the code was passed with
  `Rscript -e`. Pipelines now run from a script file next to their record.

* After the local model stopped answering in time (or a request was
  interrupted), its late reply was taken as the answer to the next question,
  so every later answer was one question behind. Requests to the inference
  worker now carry an id and replies to another request are skipped; a worker
  that times out is stopped and the next call starts a fresh one.

* `dragon_questions()` no longer errors at the very end of a long run. The
  generator reports every chunk done a moment before it writes "done";
  the progress bar closed itself at 100 percent and the next update failed
  with "Cannot find progress bar", after all the questions had been
  written.
* A run is no longer marked failed by an out-of-memory error in the
  evaluation after training. Held-out loss is computed in chunks through the
  output layer, optimizer state is released first, and a run whose
  evaluation still cannot fit succeeds with an `eval_warning`. Peak
  evaluation memory at 4 x 1536 tokens fell from 7.9 GB to 2.4 GB with the
  same loss. `dragon_train_args()` gains `eval_batch_size` (default 1).
* Large requests to the inference worker no longer hang: replies longer than
  processx's line buffer are reassembled, and big requests are written in a
  loop.
* `dragon_example_data()` no longer contains duplicate tickets, so held-out
  numbers are not inflated by verbatim repeats. The tickets are synthetic;
  treat them as a smoke test, not a benchmark.

# dragonfarm 0.3.4

* Fixed a test that failed on macOS (CRAN's M1mac additional check) though it
  passed everywhere else. It compared `dragon_runs_dir()`'s default, a
  directory that does not exist yet, against `tempdir()` after
  `normalizePath()`; on macOS that resolves `/var` to `/private/var` for the
  existing `tempdir()` but leaves the nonexistent path unresolved, so the
  prefix check failed. The test now compares the existing parent directory.
  No change to package code or behaviour.

# dragonfarm 0.3.3

* Fixed the Shiny app's Try it, Chat, Train, and Pipeline panels sometimes
  keeping a stale runs list until the page was reloaded -- most visibly, a
  run that had just finished training would not appear as selectable in Try
  it. Their `reactivePoll()`s watched only each run's own `status.json`
  mtime, which misses a change when the file that actually matters (the
  adapter, or a run's directory being renamed by archive/restore) is written
  or moved without `status.json` itself changing again. All of the app's
  run-list pollers now share `runs_change_signature()`, which changes
  whenever any file anywhere under the runs directory is added, edited, or
  moved.

# dragonfarm 0.3.2

* The 0.3.1 fix for the torchao `ImportError` on cloud GPUs (pinning
  `torchao>=0.16.0` in requirements) turned out not to be reliably honoured on
  Colab's and Kaggle's preinstalled environment (pip reported success but the
  old 0.10.0 build was still what got imported). The requirements pin is
  reverted, and the shared remote notebook (`inst/remote/dragonfarm_remote.ipynb`,
  used by `dragon_remote()` for Colab, Kaggle, Lightning AI, and RunPod) now
  explicitly uninstalls torchao after installing the trainer's requirements.
  dragonfarm never imports torchao itself, and peft's LoRA dispatch skips its
  torchao check cleanly when the package is entirely absent rather than
  present at an old version, so removing it sidesteps the problem instead of
  depending on pip to upgrade it in place.

# dragonfarm 0.3.1

* Fixed cloud training (`dragon_remote()` on Colab, Kaggle, Lightning AI, and
  RunPod) failing with `ImportError: Found an incompatible version of
  torchao`. dragonfarm never uses torchao, but recent `peft` versions probe
  it while dispatching LoRA and raise instead of skipping when an older
  version is already installed, which Colab and Kaggle's base images ship by
  default. `dragon_python_requirements()` now pins `torchao>=0.16.0` so the
  bundled `requirements.txt` installs a compatible version.

# dragonfarm 0.3.0

CRAN maintainers reviewed 0.1.1 and asked for several changes, folded into
this release along with everything added since 0.2.0:

* **Where runs are stored by default has changed.** `dragon_runs_dir()` used
  to default to `dragonfarm_runs` under the working directory; a package
  must not write there without being asked. It now defaults to
  `dragonfarm_runs` under a session temp directory, so a fresh R session
  never writes to your project or home folder on its own, and that folder
  disappears when the session ends. For runs you want to keep, set
  `options(dragonfarm.runs_dir = "path/to/dragonfarm_runs")` or the
  `DRAGONFARM_RUNS_DIR` environment variable once, or pass `runs_dir=` to
  the function you're calling. See `?dragon_runs_dir` and the README.
* Fixed three places (`dragon_judge()`, `dragon_split()`,
  `dragon_synthesize()`/`dragon_prompts()`) that saved and restored
  `.Random.seed` by hand for a seeded sample; they now use
  `withr::with_seed()`, which does the same thing without dragonfarm's own
  code touching `.GlobalEnv`. `withr` moved from Suggests to Imports.
  `dragon_resume()`'s log line now goes through a small file-append helper
  rather than `cat()`.
* Examples that need Python, a GPU, or a model download now use
  `if (interactive())` instead of `\dontrun{}`, so `R CMD check` at least
  parses them; they still don't run during checks or on CRAN's servers.
* Package and software names in the `Title` and `Description` fields are
  now quoted and cased correctly (`'Python'`, `'shiny'`), and quotes were
  removed from `LoRA`, which is a technique name, not a package.
* Added `testthat`-based tests for the three app modules (Data, Model, Try
  it) that had none, covering their server logic without needing a real
  Shiny session, Python, or a GPU.

## Everything else added since 0.2.0

* `dragon_reward("command", command = ...)`: a reward for `dragon_reinforce()`
  that runs a command (a test suite, a linter) against the completion and
  scores by its exit code or a number in its stdout. Runs the command
  directly, never through a shell, so the completion's own text cannot
  inject anything into the command line.

* The Chat tab streams replies token by token, for the local worker and for
  server backends alike, instead of showing the whole reply only once
  generation finishes. Compare mode still shows each side's full reply once
  it lands.

* Starting a training run now stops the local inference worker first, if
  one is loaded from an earlier Try it or Chat call. Two heavy Python/CUDA
  processes starting at the same moment has occasionally crashed a fresh
  trainer on Windows; freeing the worker's GPU memory first is the most
  likely trigger and costs nothing, since the worker restarts automatically
  on the next generation call.

* The Python side (`inst/python`) is now also its own installable package:
  `pip install ./inst/python` (or a built wheel) gives a `dragonfarm`
  command (`check`, `train`, `generate`, `pack`) and a `dragonfarm.api`
  module (`Run`, `runs()`) for reading a run directory from plain Python,
  with no R involved. A run started from R can be inspected or continued
  from Python and back, since both read and write the same files. Not yet
  published to PyPI.

* Runs can be archived, restored, and deleted. `dragon_archive_run()` moves
  a run's directory under `archived/` (every file kept; it just drops out
  of `dragon_runs()` and the app); `dragon_unarchive_run()` brings it back;
  `dragon_delete_run()` removes it for good. Both refuse a run that is
  queued or running, or one that another run continues from, unless
  `force = TRUE`. The Monitor panel gets Archive and Delete buttons (Delete
  asks for confirmation first), a "Show archived" toggle, and Restore.

* Chat gets context limits, a second backend to compare with, and transcript
  round-tripping in the app. `dragon_chat(context_window=)` tracks an
  approximate token budget and automatically drops the oldest turns to stay
  under it; `$context_usage()` reports tokens used, the window, and how many
  turns were dropped. The Chat tab shows a warning banner near the limit, a
  "Compare with a second backend" toggle sends the same message to a second
  backend or run side by side (feedback stays scoped to the primary
  conversation), and Load transcript / Export as training example round out
  Save transcript.
* Fixed a bug in the Chat tab (introduced while building the above) where
  Shiny's default "suspend when hidden" behaviour left the conversation
  panes permanently blank the first time the tab was opened, because they
  sit behind a `renderUI()` rather than being part of the tab's static
  markup; the affected outputs now opt out of that suspension.

* `dragon_synthesize()` gets a quality pass and a judge filter. It now
  drops replies that are too short or too long, look garbled or
  wrong-script, repeat an earlier prompt, or repeat (or nearly repeat) an
  earlier response, before writing the dataset. Passing a `judge` scores
  every surviving reply and keeps only the ones at or above `min_score`,
  for teacher distillation with a quality gate -- pass a run's own prompts
  (`dragon_prompts(run, "train")`) to distill and filter in one call.

* The app no longer freezes on long actions. Evaluate, Run judge, Build
  preference pairs, and Merge run as one-step background pipelines; the
  panel shows progress, the result appears when it lands, and the Pipeline
  panel lists them.
* `dragon_pipeline_cancel()` and a Cancel button on running pipelines. A
  training step in flight stops after saving a checkpoint; other steps
  finish first. Records now carry the runner's pid, so a pipeline whose
  process died reads as failed instead of running forever.
* `dragon_step_merge()`: a pipeline step that writes the latest run as a
  standalone model.
* `dragon_publish()`: push a run's merged model or adapter to a repo on the
  Hugging Face Hub, creating it if needed. `dragon_step_publish()` for
  pipelines, and a Publish card in the app's Try it panel.

* Human feedback becomes data. In `dragon_chat()` and the app's Chat panel,
  replies can be rated up or down, edited, or regenerated; every verdict is
  saved under `feedback/`. `dragon_feedback()` turns them into a
  conversations dataset of liked and edited replies and a preference-pairs
  dataset where the same prompt drew a liked and a disliked reply.
* `dragon_conversations()`: whole multi-turn conversations as training
  data, from a list, a JSONL file, or a data frame. They train wherever
  prompt and response rows do.
* Two new vignettes: the post-training loop, and reinforcement learning
  with verifiable rewards.

* Inference backends. `dragon_generate()` and everything built on it now
  route through a `backend`: `dragon_backend_local()` is a Python worker
  that keeps the last two models loaded, so repeated calls no longer reload
  the model; `dragon_backend_server()` talks to any OpenAI-compatible chat
  endpoint (vLLM, llama.cpp, LM Studio, hosted services), and
  `dragon_backend_ollama()` to Ollama. `dragon_serve_ollama()` merges a run
  and registers it with Ollama in one call. `dragon_worker_stop()` frees the
  worker's memory. Set a session default with `options(dragonfarm.backend)`.
* `dragon_chat()`: a conversation object with memory, streaming through
  `on_token` where the backend supports it, save and load of transcripts,
  and export of a conversation as a training example. The app gains a Chat
  panel with a backend selector and a system prompt.

# dragonfarm 0.2.0

* Pipelines. `dragon_pipeline()` chains stages built from `dragon_step_*()`
  constructors (train, synthesize pairs, prefer, reinforce, judge,
  evaluate), threading each stage's run into the next and writing a record
  after every step. `background = TRUE` runs it in a separate R process;
  `dragon_pipeline_status()` follows it. `dragon_compare()` accepts a
  pipeline. The app gains a Pipeline panel that launches the standard
  recipe and shows every run's lineage.

* Reinforcement learning. `dragon_map_prompts()` maps prompts with an
  optional reference answer, `dragon_reward()` defines verifiable rewards
  (exact, contains, numeric, regex, JSON, length, keyword, or a custom
  Python function), and `dragon_reinforce()` runs GRPO: the model samples a
  group of answers per prompt, the rewards score them, and it learns from
  the ones that beat their group's average, with a KL penalty towards the
  model it started from. Implemented in the package's own trainer, so no
  new dependency. Evaluation reports mean held-out reward per reward; the
  app's Map and Train panels gain an RL mode with a reward builder.

* Synthetic data closes the loop. `dragon_synthesize()` has a teacher model
  answer your prompts to make fine-tuning data; `dragon_synthesize_pairs()`
  samples a run's own replies, has a judge score them, and keeps the best
  and worst as preference pairs (or pairs a teacher's reply against the
  student's). `dragon_prompts()` pulls prompts from a run's data files.
  `dragon_llm_anthropic()` and `dragon_llm_ellmer()` turn the Claude API or
  any ellmer chat into a teacher; the judge variants are now wrappers over
  them. The app's Try it panel gains an Improve card that builds pairs from
  the selected run and loads them for the next stage.

* Evaluation that can drive decisions. `dragon_evaluate()` gains `metrics`:
  deterministic task checks (exact match, token F1, JSON validity, numeric
  answers, length, custom functions) over every held-out row.
  `dragon_judge()` scores a run's replies with a language model or compares
  them pairwise with the model it started from, with position swapping so a
  biased judge produces ties rather than wins; `dragon_judge_anthropic()`
  talks to the Claude API directly and `dragon_judge_ellmer()` wraps any
  ellmer chat, and any local model can judge too. `dragon_compare()` puts
  every run's measurements side by side. The app gains task metrics and a
  comparison table in Monitor and a Judge card in Try it.

* Post-training stages. `dragon_map_pairs()` maps prompt, chosen, and
  rejected columns, and `dragon_prefer()` runs preference optimization on
  them with DPO or ORPO. Any function that takes a `model` also accepts a
  finished run: its adapters are folded into the weights before the new
  stage adds its own, so fine-tune then prefer chains naturally, locally or
  through the cloud bundle. Runs record their `stage`, `dragon_evaluate()`
  reports preference accuracy and reward margin, and the app's Map and Train
  panels gain a preference-pairs mode and a "Start from" run picker.

* Driver download link updated to NVIDIA's canonical URL, which CRAN's URL
  check had flagged as a redirect.

# dragonfarm 0.1.1

* `dragon_check()` now explains a CPU-only result on a machine with an NVIDIA
  GPU: no driver, a driver too old for the installed torch, or a CPU-only
  torch build, each with the one-line fix.
* README gains a Requirements section covering the driver requirement, disk
  space, and that the CUDA Toolkit is not needed.
* New `dragon_bundle()`, `dragon_remote()`, and `dragon_import()` take a run to
  a cloud GPU (Google Colab, Kaggle, Lightning AI, or RunPod) and bring the
  trained adapter back, for machines without a GPU. `dragon_remote_providers()`
  lists the providers. The app gains the same path in its Train and Monitor
  panels, and `dragon_check()` points to it when it finds no GPU.

# dragonfarm 0.1.0

First release.

* `dragon_dataset()`, `dragon_map()`, and `dragon_split()` turn a table into
  chat-format training data with glue templates for combining columns.
* `dragon_train()` runs LoRA fine-tuning of any Hugging Face causal language
  model in a background Python process. Runs live on disk and survive the R
  session; `dragon_run()` reopens them.
* `dragon_status()`, `dragon_progress()`, `dragon_logs()`, `dragon_wait()`,
  `dragon_cancel()`, and `dragon_resume()` manage a run.
* `dragon_evaluate()`, `dragon_generate()`, and `dragon_merge()` cover
  held-out evaluation, generation from the adapter or the base model, and
  merging into a standalone model. `dragon_export_gguf()` wraps the llama.cpp
  converter when one is available.
* `dragon_app()` launches a Shiny app with drag-and-drop dataset upload,
  drag-and-drop column mapping, a live loss curve, and a before-and-after
  comparison panel. `dragon_code()` returns the R script for any run.
* Python dependencies are declared with `reticulate::py_require()` and built
  automatically. On Windows with an NVIDIA GPU the CUDA build of torch is
  selected on first use.
