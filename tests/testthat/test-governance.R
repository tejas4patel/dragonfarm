# Governance checks (T7): licence, provenance, deletion impact, each on
# planted cases.

gov_run <- function(runs, id, model = "HuggingFaceTB/SmolLM2-135M-Instruct", documents = NULL, base_run = NULL, source = "tickets.csv") {
  d <- file.path(runs, id)
  dir.create(file.path(d, "data"), recursive = TRUE)
  jsonlite::write_json(list(run_id = id, created_at = "2026-10-18T10:00:00Z", stage = "sft",
                            model = list(id = model, revision = "abc123", trust_remote_code = FALSE, allow_pickle = FALSE, base_run = base_run),
                            data = list(train = "data/train.jsonl", eval = "data/eval.jsonl", n_train = 2, n_eval = 1)),
                       file.path(d, "config.json"), auto_unbox = TRUE, null = "null")
  jsonlite::write_json(list(source = source, name = "tickets", mapping = list(prompt = "{subject}", response = "{reply}"), documents = documents),
                       file.path(d, "dataset.json"), auto_unbox = TRUE, null = "null")
  jsonlite::write_json(list(state = "succeeded", eval_loss = 1.1), file.path(d, "status.json"), auto_unbox = TRUE)
  writeLines(c('{"prompt": "a", "response": "b"}', '{"prompt": "c", "response": "d"}'), file.path(d, "data", "train.jsonl"))
  writeLines('{"prompt": "e", "response": "f"}', file.path(d, "data", "eval.jsonl"))
  d
}

test_that("licences: presets, local model cards, and unknown without a lookup", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  l <- dragonfarm:::model_licence("HuggingFaceTB/SmolLM2-135M-Instruct", runs_dir = runs)
  expect_equal(l$licence, "apache-2.0"); expect_equal(l$kind, "permissive"); expect_equal(l$from, "preset list")
  q3 <- dragonfarm:::model_licence("Qwen/Qwen2.5-3B-Instruct", runs_dir = runs)
  expect_equal(q3$licence, "qwen-research"); expect_equal(q3$kind, "check_terms"); expect_match(q3$note, "terms of its own")
  expect_equal(dragonfarm:::model_licence("google/gemma-3-1b-it", runs_dir = runs)$kind, "check_terms")

  mit <- withr::local_tempdir(); writeLines(c("---", "license: mit", "tags: [x]", "---", "# A model"), file.path(mit, "README.md"))
  expect_equal(dragonfarm:::model_licence(mit, runs_dir = runs)[c("licence", "kind", "from")],
               list(licence = "mit", kind = "permissive", from = "local model card"))
  other <- withr::local_tempdir(); writeLines(c("---", "license: \"other\"", "---"), file.path(other, "README.md"))
  expect_equal(dragonfarm:::model_licence(other, runs_dir = runs)$kind, "check_terms")
  bare <- withr::local_tempdir()
  b <- dragonfarm:::model_licence(bare, runs_dir = runs)
  expect_equal(b$kind, "unknown"); expect_null(b$licence); expect_match(b$from, "no model card")
  nocard <- withr::local_tempdir(); writeLines(c("# No front matter", "license: mit"), file.path(nocard, "README.md"))
  expect_equal(dragonfarm:::model_licence(nocard, runs_dir = runs)$kind, "unknown")   # only front matter counts

  u <- dragonfarm:::model_licence("someone/unlisted-model", runs_dir = runs)
  expect_equal(u$kind, "unknown"); expect_equal(u$from, "not looked up")
})

test_that("a licence lookup respects the offline switch and the outbound policy", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  pol <- dragonfarm:::policy_current(runs); pol$version <- NULL
  pol$outbound$offline <- TRUE
  dragonfarm:::policy_set(pol, set_by = "admin", note = "offline", runs_dir = runs)
  expect_equal(dragonfarm:::model_licence("someone/unlisted-model", lookup = TRUE, runs_dir = runs)$from, "not looked up (offline)")

  skip_if_not_installed("httr2")
  pol$outbound$offline <- FALSE; pol$outbound$allowed_hosts <- list()
  dragonfarm:::policy_set(pol, set_by = "admin", note = "nowhere", runs_dir = runs)
  r <- dragonfarm:::model_licence("someone/unlisted-model", lookup = TRUE, runs_dir = runs)
  expect_equal(r$kind, "unknown"); expect_match(r$from, "no answer")
  ev <- dragonfarm:::store_events(5, kind = "outbound", runs_dir = runs)
  expect_equal(ev$name, "huggingface.co"); expect_equal(ev$ok, 0L)              # refused, and recorded
})

test_that("a Hub answer gives the licence from the model card data or the tags", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  skip_if_not_installed("httr2")
  answers <- list(list(cardData = list(license = "llama3.1")), list(tags = list("text-generation", "license:apache-2.0")))
  i <- 0
  local_mocked_bindings(outbound_check = function(...) invisible(TRUE), .package = "dragonfarm")
  local_mocked_bindings(req_perform = function(req) { i <<- i + 1; req }, resp_body_json = function(resp) answers[[i]], .package = "httr2")
  expect_equal(dragonfarm:::model_licence("meta-llama/x", lookup = TRUE, runs_dir = runs)[c("licence", "kind")],
               list(licence = "llama3.1", kind = "check_terms"))
  expect_equal(dragonfarm:::model_licence("org/y", lookup = TRUE, runs_dir = runs)[c("licence", "kind")],
               list(licence = "apache-2.0", kind = "permissive"))
})

test_that("a run's provenance names its data, documents, approval and versions", {
  fake <- write_fake_set()
  runs <- fake$root
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  dragonfarm:::store_sync(runs)                                         # the set is version 1
  md5 <- unname(tools::md5sum(file.path(fake$dir, "chunks.jsonl")))
  d <- gov_run(runs, "run-docs", documents = list(set = "kb", dir = fake$dir, chunks_md5 = md5, questions = file.path(fake$dir, "questions", "q.jsonl")))
  dragonfarm:::store_record_event("run_created", "run-docs", ok = TRUE, runs_dir = runs,
                                  detail = list(personal_data = list(event = 7L, rows = 3L, approved_by = "qa.lead")))
  dragonfarm:::registry_propose(dragon_run(d), "kb-bot", proposed_by = "tejas", runs_dir = runs)
  dragonfarm:::registry_sign_off("kb-bot", 1, "approved", meaning = "Approved for answering from kb.", signer = "qa.lead", runs_dir = runs)

  p <- dragonfarm:::provenance_report("run-docs", runs_dir = runs)
  expect_equal(p$model$id, "HuggingFaceTB/SmolLM2-135M-Instruct"); expect_equal(p$model$revision, "abc123")
  expect_equal(p$licence$kind, "permissive")
  expect_equal(p$data$train_md5, unname(tools::md5sum(file.path(d, "data", "train.jsonl"))))
  expect_equal(p$documents$set, "kb"); expect_equal(p$documents$version, 1L); expect_true(p$documents$current)
  expect_equal(p$personal_data$approved_by, "qa.lead")
  expect_equal(p$registry$status, "approved")
  txt <- dragonfarm:::provenance_text(p)
  expect_match(txt, "Base model: HuggingFaceTB/SmolLM2-135M-Instruct at revision abc123", fixed = TRUE)
  expect_match(txt, "set kb, version 1 (still the current version)", fixed = TRUE)
  expect_match(txt, "training approved by qa.lead", fixed = TRUE)
  expect_match(txt, "kb-bot version 1: approved (qa.lead", fixed = TRUE)

  # The set is re-read: the report says the run was trained on an older version.
  dragonfarm:::write_jsonl(list(list(id = "abc-000", source = "policy.pdf", section = "Returns", text = "Sixty days.")),
                           file.path(fake$dir, "chunks.jsonl"))
  dragonfarm:::store_sync(runs)
  p2 <- dragonfarm:::provenance_report("run-docs", runs_dir = runs)
  expect_equal(p2$documents$version, 1L); expect_false(p2$documents$current)
  expect_match(dragonfarm:::provenance_text(p2), "re-read since")
})

test_that("a run with nothing recorded still gets a plain report", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  gov_run(runs, "run-bare", model = "someone/unlisted-model")
  p <- dragonfarm:::provenance_report("run-bare", runs_dir = runs)
  expect_true(is.na(p$started_by)); expect_null(p$documents); expect_equal(p$licence$kind, "unknown")
  txt <- dragonfarm:::provenance_text(p)
  expect_match(txt, "who created it is not recorded"); expect_match(txt, "Not proposed as a model version")
  expect_match(txt, "none (trained from the base model)", fixed = TRUE)
  p$data$prompt <- "{subject}\n\n{body}"
  expect_match(dragonfarm:::provenance_text(p), "- Prompt: `{subject}\\n\\n{body}`;", fixed = TRUE)   # one line, as typed
  expect_error(dragonfarm:::provenance_report("no-such-run", runs_dir = runs), class = "dragonfarm_error")
})

test_that("creating a run records who, from what, and a personal-data approval", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  withr::local_options(dragonfarm.user = "analyst.one",
                       dragonfarm.approval = list(event = 3L, rows = 2L, approved_by = "analyst.one"))
  ds <- dragon_map(dragon_dataset(data.frame(p = c("a", "b", "c"), r = c("x", "y", "z"))), prompt = "p", response = "r")
  ds$documents <- list(set = "kb", chunks_md5 = "m1")
  prep <- dragonfarm:::prepare_run(ds, "HuggingFaceTB/SmolLM2-135M-Instruct", dragon_lora(), dragon_train_args(), dragon_hardware(),
                                   name = "t", run_dir = NULL, runs_dir = runs, n_samples = 0)
  ev <- dragonfarm:::store_events(5, kind = "run_created", runs_dir = runs)
  expect_equal(ev$name, basename(prep$run_dir)); expect_equal(ev$actor, "analyst.one")
  det <- jsonlite::fromJSON(ev$detail)
  expect_equal(det$documents, "kb"); expect_equal(det$personal_data$rows, 2L)
  expect_equal(jsonlite::read_json(file.path(prep$run_dir, "dataset.json"))$documents$set, "kb")
  p <- dragonfarm:::provenance_report(dragon_run(prep$run_dir), runs_dir = runs)
  expect_equal(p$started_by, "analyst.one"); expect_equal(p$personal_data$approved_by, "analyst.one")
})

test_that("a training set built from questions carries its document set", {
  fake <- write_fake_set()
  qpath <- write_fake_questions(fake$dir)
  local_mocked_bindings(dragon_retrieve = function(docs, queries, k = 4, ...) {
    data.frame(query = rep(queries, each = 1), id = "abc-000", source = "policy.pdf", section = "Returns", page = NA_integer_,
               text = "Thirty days.", stringsAsFactors = FALSE)
  })
  ds <- dragon_questions_dataset(dragon_questions_load(qpath), docs = fake$dir, negatives = 0)
  expect_equal(ds$documents$set, "kb")
  expect_equal(ds$documents$chunks_md5, unname(tools::md5sum(file.path(fake$dir, "chunks.jsonl"))))
  expect_equal(basename(ds$documents$questions), basename(qpath))
})

test_that("deletion impact: runs continuing from a run, and everything trained from a set", {
  fake <- write_fake_set()
  runs <- fake$root
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  write_fake_questions(fake$dir)
  writeLines("{}", file.path(fake$dir, "questions", "20261012-120000-training.jsonl"))   # not counted as a question file
  a <- gov_run(runs, "run-a", documents = list(set = "kb"))
  gov_run(runs, "run-b", base_run = "run-a")                                      # continues from run-a
  gov_run(runs, "run-c", source = file.path(fake$dir, "questions", "20261012-120000-training.jsonl"))   # set found from the file
  gov_run(runs, "run-other")
  dragonfarm:::registry_propose(dragon_run(a), "kb-bot", proposed_by = "tejas", runs_dir = runs)
  dragonfarm:::registry_sign_off("kb-bot", 1, "approved", meaning = "Approved for kb answers.", signer = "qa", runs_dir = runs)

  r <- dragonfarm:::deletion_impact(run = "run-a", runs_dir = runs)
  expect_equal(unlist(r$runs), "run-b"); expect_equal(r$approved_versions, 1L)
  expect_match(r$note, "1 run continuing from it, 1 model version"); expect_match(r$note, "1 of those model versions is approved")

  s <- dragonfarm:::deletion_impact(set = "kb", runs_dir = runs)
  expect_setequal(unlist(s$runs), c("run-a", "run-c")); expect_equal(s$question_files, 1L)
  expect_match(s$note, "1 question file, 2 runs trained from it, 1 model version")

  expect_equal(dragonfarm:::deletion_impact(run = "run-other", runs_dir = runs)$note, "Nothing else depends on it.")
  expect_error(dragonfarm:::deletion_impact(runs_dir = runs), class = "dragonfarm_error")
  expect_error(dragonfarm:::deletion_impact(run = "run-a", set = "kb", runs_dir = runs), "not both")
})

test_that("the three governance tools are well formed and read-only", {
  fake <- write_fake_set()
  runs <- fake$root
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  gov_run(runs, "run-a", documents = list(set = "kb"))
  reg <- dragonfarm:::tool_registry(refresh = TRUE)
  for (nm in c("check_licence", "provenance_report", "deletion_impact")) {
    expect_equal(dragonfarm:::tool_contract_problems(reg[[nm]], paste0(nm, ".json")), character())
    expect_equal(reg[[nm]]$side_effect, "read_only")
  }
  l <- dragonfarm:::tool_call("check_licence", list(model = "Qwen/Qwen2.5-3B-Instruct"))
  expect_true(l$ok); expect_equal(l$result$kind, "check_terms")
  p <- dragonfarm:::tool_call("provenance_report", list(run = "run-a"))
  expect_true(p$ok); expect_match(p$result$report, "# Provenance of run run-a", fixed = TRUE)
  expect_equal(dragonfarm:::tool_call("provenance_report", list(run = "nope"))$code, "NOT_A_RUN")
  d <- dragonfarm:::tool_call("deletion_impact", list(set = "kb"))
  expect_true(d$ok); expect_equal(unlist(d$result$runs), "run-a")
  expect_equal(dragonfarm:::tool_call("deletion_impact", list(set = "nope"))$code, "NOT_A_SET")
  expect_equal(dragonfarm:::tool_call("deletion_impact", list(run = "run-a", set = "kb"))$code, "INVALID_ARGUMENTS")
})

test_that("before signing: each planted concern is a finding, a clean run has none", {
  fake <- write_fake_set()
  runs <- fake$root
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  dragonfarm:::store_sync(runs)
  md5 <- unname(tools::md5sum(file.path(fake$dir, "chunks.jsonl")))
  clean <- gov_run(runs, "run-clean", documents = list(set = "kb", chunks_md5 = md5))
  dragonfarm:::store_record_event("run_created", "run-clean", ok = TRUE, detail = list(personal_data_rows = 0L), runs_dir = runs)
  f <- dragonfarm:::governance_findings("run-clean", runs_dir = runs)
  expect_true(all(f$status == "ok")); expect_setequal(f$check, c("licence", "personal_data", "documents"))

  risky <- gov_run(runs, "run-risky", model = "Qwen/Qwen2.5-3B-Instruct", documents = list(set = "kb", chunks_md5 = "an-older-version"))
  cfg <- jsonlite::read_json(file.path(risky, "config.json")); cfg$model$trust_remote_code <- TRUE
  jsonlite::write_json(cfg, file.path(risky, "config.json"), auto_unbox = TRUE, null = "null")
  jsonlite::write_json(list(state = "succeeded"), file.path(risky, "status.json"), auto_unbox = TRUE)   # no evaluation
  dragonfarm:::store_record_event("run_created", "run-risky", ok = TRUE, detail = list(personal_data_rows = 4L), runs_dir = runs)
  f2 <- dragonfarm:::governance_findings("run-risky", runs_dir = runs)
  look <- f2$check[f2$status == "look"]
  expect_setequal(look, c("licence", "personal_data", "documents", "remote_code", "evaluation"))
  expect_setequal(f2$check[f2$blocks], c("personal_data", "documents"))   # D-17: only these two hold an approval
  expect_match(f2$note[f2$check == "personal_data"], "4 rows .* no approval recorded")
  expect_match(f2$note[f2$check == "documents"], "re-read since")      # the set no longer holds what it was trained on

  # A re-read set after training is flagged.
  dragonfarm:::write_jsonl(list(list(id = "abc-000", source = "policy.pdf", section = "Returns", text = "Sixty days.")),
                           file.path(fake$dir, "chunks.jsonl"))
  dragonfarm:::store_sync(runs)
  f3 <- dragonfarm:::governance_findings("run-clean", runs_dir = runs)
  expect_equal(f3$status[f3$check == "documents"], "look"); expect_match(f3$note[f3$check == "documents"], "re-read since")

  old <- gov_run(runs, "run-old")                                      # predates the run_created event
  f4 <- dragonfarm:::governance_findings("run-old", runs_dir = runs)
  expect_equal(f4$status[f4$check %in% c("personal_data", "creator")], c("unknown", "unknown"))
})

test_that("a run records how many rows held personal data, and a sign-off keeps the findings", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  withr::local_options(dragonfarm.user = "analyst.one")
  ds <- dragon_map(dragon_dataset(data.frame(p = c("Mail jane.doe@example.org", "b", "c"), r = c("x", "y", "z"))), prompt = "p", response = "r")
  prep <- dragonfarm:::prepare_run(ds, "HuggingFaceTB/SmolLM2-135M-Instruct", dragon_lora(), dragon_train_args(), dragon_hardware(),
                                   name = "t", run_dir = NULL, runs_dir = runs, n_samples = 0)
  jsonlite::write_json(list(state = "succeeded", eval_loss = 1.0), file.path(prep$run_dir, "status.json"), auto_unbox = TRUE)
  expect_equal(jsonlite::fromJSON(dragonfarm:::store_events(1, kind = "run_created", runs_dir = runs)$detail)$personal_data_rows, 1L)
  f <- dragonfarm:::governance_findings(dragon_run(prep$run_dir), runs_dir = runs)
  expect_equal(f$status[f$check == "personal_data"], "look")

  dragonfarm:::registry_propose(dragon_run(prep$run_dir), "bot", proposed_by = "someone.else", runs_dir = runs)
  # D-17: personal data with no recorded approval holds the approval until the signer ticks "reviewed".
  expect_error(dragonfarm:::registry_sign_off("bot", 1, "approved", meaning = "Approved for testing.", signer = "qa", runs_dir = runs),
               class = "dragonfarm_error", regexp = "reviewed")
  expect_equal(dragonfarm:::registry_status("bot", 1, runs), "candidate")
  dragonfarm:::registry_sign_off("bot", 1, "approved", meaning = "Approved for testing.", signer = "qa", runs_dir = runs, reviewed = TRUE)
  det <- jsonlite::fromJSON(dragonfarm:::store_events(1, kind = "model_signoff", runs_dir = runs)$detail, simplifyVector = FALSE)
  expect_equal(vapply(det$findings, `[[`, "", "check"), "personal_data")   # only what was not ok is kept
  expect_true(det$reviewed)
})

test_that("Monitor shows the findings before a version is signed", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  d <- gov_run(runs, "20261018-run1", model = "Qwen/Qwen2.5-3B-Instruct")
  dragonfarm:::registry_propose(dragon_run(d), "kb-bot", proposed_by = "tejas", runs_dir = runs)
  state <- shiny::reactiveValues(run = NULL, dataset = NULL)
  shiny::testServer(dragonfarm:::mod_monitor_server, args = list(state = state, runs_dir = runs), {
    session$setInputs(reg_pick = "kb-bot@1")
    html <- output$reg_findings$html
    expect_match(html, "Before you sign"); expect_match(html, "qwen-research"); expect_match(html, "text-warning")
  })
})

test_that("D-17: a re-read set holds approval; rejecting needs no tick; Monitor shows the tick", {
  fake <- write_fake_set()
  runs <- fake$root
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  dragonfarm:::store_sync(runs)
  d <- gov_run(runs, "20261018-kb", documents = list(set = "kb", chunks_md5 = "an-older-version"))
  dragonfarm:::store_record_event("run_created", "20261018-kb", ok = TRUE, detail = list(personal_data_rows = 0L), runs_dir = runs)
  dragonfarm:::registry_propose(dragon_run(d), "kb-bot", proposed_by = "tejas", runs_dir = runs)
  e <- tryCatch(dragonfarm:::registry_sign_off("kb-bot", 1, "approved", meaning = "For kb.", signer = "qa", runs_dir = runs), error = function(e) e)
  expect_equal(e$code, "NEEDS_REVIEW"); expect_match(conditionMessage(e), "re-read since training")
  expect_true("NEEDS_REVIEW" %in% dragonfarm:::tool_error_codes())
  state <- shiny::reactiveValues(run = NULL, dataset = NULL)
  shiny::testServer(dragonfarm:::mod_monitor_server, args = list(state = state, runs_dir = runs), {
    session$setInputs(reg_pick = "kb-bot@1")
    expect_match(output$reg_findings$html, "Holds approval until reviewed")
    expect_match(output$reg_findings$html, "reg_reviewed")
    session$setInputs(reg_decision = "approved", reg_meaning = "For kb answers", reg_sign = 1)
    expect_equal(dragonfarm:::registry_status("kb-bot", 1, runs_dir), "candidate")      # held without the tick
    session$setInputs(reg_reviewed = TRUE, reg_sign = 2)
    expect_equal(dragonfarm:::registry_status("kb-bot", 1, runs_dir), "approved")
  })
  d2 <- gov_run(runs, "20261018-kb2", documents = list(set = "kb", chunks_md5 = "an-older-version"))
  dragonfarm:::registry_propose(dragon_run(d2), "kb-bot", proposed_by = "tejas", runs_dir = runs)
  dragonfarm:::registry_sign_off("kb-bot", 2, "rejected", meaning = "Stale documents.", signer = "qa", runs_dir = runs)   # no tick needed
  expect_equal(dragonfarm:::registry_status("kb-bot", 2, runs), "rejected")
})
