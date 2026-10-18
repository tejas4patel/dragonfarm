# A judge that answers from the prompt text, so verdicts are deterministic.
fake_pair_judge <- function(prefer) {
  function(prompts) {
    vapply(prompts, function(p) {
      a <- sub(".*Reply A:\\n(.*?)\\n\\nReply B:.*", "\\1", p)
      b <- sub(".*Reply B:\\n(.*?)\\n\\nRespond with JSON.*", "\\1", p)
      winner <- if (a == prefer) "A" else if (b == prefer) "B" else "tie"
      sprintf('{"winner": "%s", "reason": "because"}', winner)
    }, character(1), USE.NAMES = FALSE)
  }
}

test_that("parse_judge_json tolerates fences, prose, and junk", {
  p <- dragonfarm:::parse_judge_json
  expect_equal(p('{"score": 7, "reason": "ok"}')$score, 7)
  expect_equal(p("```json\n{\"score\": 3, \"reason\": \"meh\"}\n```")$score, 3)
  expect_equal(p("Sure! Here you go: {\"winner\": \"B\", \"reason\": \"x\"} hope that helps")$winner, "B")
  expect_null(p("no json here"))
  expect_null(p("__error__ refusal"))
  expect_null(p(NA_character_))
  expect_null(p("{not valid"))
})

test_that("judge_scores averages parsed scores and counts failures", {
  judge <- function(prompts) c('{"score": 8, "reason": "a"}', "garbage", '{"score": 40, "reason": "clamped"}')
  res <- dragonfarm:::judge_scores(c("q1", "q2", "q3"), c("r1", "r2", "r3"), c("ref", NA, NA), judge)
  expect_equal(res$mode, "score")
  expect_equal(res$details$score, c(8, NA, 10))
  expect_equal(res$summary$mean_score, 9)
  expect_equal(res$summary$n, 2)
  expect_equal(res$summary$unparsed, 1)
  expect_match(res$details$reason[3], "clamped")
})

test_that("score prompts carry the rubric and the reference", {
  seen <- NULL
  judge <- function(prompts) { seen <<- prompts; rep('{"score": 5, "reason": ""}', length(prompts)) }
  dragonfarm:::judge_scores("What is 2+2?", "4", "4", judge, rubric = "Reward brevity.")
  expect_match(seen, "Reward brevity.", fixed = TRUE)
  expect_match(seen, "Reference answer:\n4", fixed = TRUE)
  expect_match(seen, "What is 2+2?", fixed = TRUE)
})

test_that("pairwise judging swaps positions and only credits consistent verdicts", {
  prompts <- c("p1", "p2", "p3")
  a <- c("good", "same", "bad")
  b <- c("bad", "same", "good")
  res <- dragonfarm:::judge_pairs(prompts, a, b, fake_pair_judge("good"))
  expect_equal(res$mode, "pairwise")
  expect_equal(res$details$verdict, c("a", "tie", "b"))
  expect_equal(res$summary$win_rate, 1 / 3)
  expect_equal(res$summary$loss_rate, 1 / 3)
  expect_equal(res$summary$tie_rate, 1 / 3)
  expect_equal(res$summary$position_consistency, 1)
  expect_equal(res$summary$n, 3)
})

test_that("a position-biased judge produces ties, not wins", {
  always_a <- function(prompts) rep('{"winner": "A", "reason": "first!"}', length(prompts))
  res <- dragonfarm:::judge_pairs(c("p1", "p2"), c("x", "y"), c("u", "v"), always_a)
  expect_equal(res$details$verdict, c("tie", "tie"))
  expect_equal(res$summary$position_consistency, 0)
  expect_equal(res$summary$win_rate, 0)
})

test_that("unparseable pairwise replies are excluded", {
  flaky <- function(prompts) c('{"winner": "A", "reason": ""}', "???", '{"winner": "B", "reason": ""}', '{"winner": "A", "reason": ""}')
  res <- dragonfarm:::judge_pairs(c("p1", "p2"), c("a1", "a2"), c("b1", "b2"), flaky)
  # prompt 1: A first, then B with the order swapped = consistent win for a
  expect_equal(res$details$verdict[1], "a")
  # prompt 2: the first pass was unparseable, so no verdict
  expect_true(is.na(res$details$verdict[2]))
  expect_equal(res$summary$n, 1)
  expect_equal(res$summary$unparsed, 1)
  expect_equal(res$summary$win_rate, 1)
})

test_that("judges that accept a schema receive one; plain ones do not", {
  got <- NULL
  with_schema <- function(prompts, schema = NULL) { got <<- schema; rep('{"score": 5, "reason": ""}', length(prompts)) }
  dragonfarm:::judge_scores("q", "r", NA, with_schema)
  expect_equal(got$properties$score$maximum, 10)
  dragonfarm:::judge_pairs("q", "a", "b", with_schema)
  expect_equal(unlist(got$properties$winner$enum), c("A", "B", "tie"))
  plain <- function(prompts) rep('{"score": 5, "reason": ""}', length(prompts))
  expect_silent(dragonfarm:::judge_scores("q", "r", NA, plain))
})

test_that("as_judge accepts functions and model ids and rejects the rest", {
  f <- function(p) p
  expect_identical(dragonfarm:::as_judge(f), f)
  local <- dragonfarm:::as_judge("org/model")
  expect_true(is.function(local))
  expect_equal(attr(local, "label"), "local:org/model")
  expect_error(dragonfarm:::as_judge(NULL), "No judge given")
  expect_error(dragonfarm:::as_judge(42), "must be a function")
})

test_that("the Claude API request is shaped correctly", {
  skip_if_not_installed("httr2")
  req <- dragonfarm:::anthropic_request("hello", model = "claude-opus-5", api_key = "sk-test", max_tokens = 300,
                                       schema = dragonfarm:::score_schema(), system = dragonfarm:::judge_system_prompt())
  expect_equal(req$url, "https://api.anthropic.com/v1/messages")
  h <- req$headers
  expect_equal(h[["anthropic-version"]], "2023-06-01")
  expect_equal(h[["anthropic-beta"]], "server-side-fallback-2026-07-01")
  body <- req$body$data
  expect_equal(body$model, "claude-opus-5")
  expect_equal(body$max_tokens, 300L)
  expect_equal(body$fallbacks, "default")
  expect_equal(body$messages[[1]]$content, "hello")
  expect_equal(body$output_config$format$type, "json_schema")
  expect_equal(body$output_config$format$schema$required, list("score", "reason"))
  expect_match(body$system, "JSON")
  plain <- dragonfarm:::anthropic_request("hello", model = "claude-opus-5", api_key = "k", temperature = 0.7)
  expect_null(plain$body$data$output_config)
  expect_null(plain$body$data$system)
  expect_equal(plain$body$data$temperature, 0.7)
  teacher <- dragon_llm_anthropic(system = "Be brief.", api_key = "")
  expect_equal(attr(teacher, "label"), "anthropic:claude-opus-5")
  judge <- dragon_judge_anthropic(model = "claude-sonnet-5", api_key = "")
  expect_equal(attr(judge, "label"), "anthropic:claude-sonnet-5")
  expect_error(judge("x"), "No Anthropic API key")
})

test_that("API replies are reduced to text and errors are marked", {
  skip_if_not_installed("httr2")
  ok <- httr2::response_json(200, body = list(stop_reason = "end_turn", content = list(list(type = "text", text = '{"score": 9}'))))
  expect_equal(dragonfarm:::anthropic_reply_text(ok), '{"score": 9}')
  refused <- httr2::response_json(200, body = list(stop_reason = "refusal", content = list()))
  expect_match(dragonfarm:::anthropic_reply_text(refused), "^__error__ refusal")
  bad <- httr2::response_json(429, body = list(error = list(message = "rate limited")))
  expect_match(dragonfarm:::anthropic_reply_text(bad), "rate limited")
  expect_match(dragonfarm:::anthropic_reply_text(simpleError("boom")), "^__error__ boom")
})

test_that("held-out prompts come from either data format", {
  # A bundled SFT run has data files on disk (the finished-run fixture does not).
  run <- suppressMessages(dragon_bundle(
    dragon_map(dragon_dataset(toy_df(60)), "subject", "reply"),
    "HuggingFaceTB/SmolLM2-135M-Instruct", runs_dir = tempfile("runs-")
  ))
  set <- dragonfarm:::eval_prompts(run, NULL, n = 2, seed = 1)
  expect_length(set$prompts, 2)          # 3 held out of 60, sampled down to n = 2
  expect_length(set$references, 2)
  expect_true(all(nzchar(set$prompts)))
  expect_true(all(grepl("^Reply", set$references)))
  all3 <- dragonfarm:::eval_prompts(run, NULL, n = 10, seed = 1)
  expect_length(all3$prompts, 3)
  none <- dragonfarm:::eval_prompts(dragon_run(copy_fixture_run()), NULL, n = 2, seed = 1)
  expect_length(none$prompts, 0)
  given <- dragonfarm:::eval_prompts(run, c("a", "b", "c"), n = 1, seed = 1)
  expect_equal(given$prompts, c("a", "b", "c"))
  expect_true(all(is.na(given$references)))

  pairs <- suppressMessages(dragon_bundle(
    dragon_map_pairs(dragon_dataset(data.frame(q = paste("Q", 1:40), g = "good", b = "bad")), "q", "g", "b"),
    "HuggingFaceTB/SmolLM2-135M-Instruct", runs_dir = tempfile("runs-")
  ))
  ps <- dragonfarm:::eval_prompts(pairs, NULL, n = 5, seed = 1)
  expect_equal(length(ps$prompts), 2)  # 5% of 40 rows held out
  expect_true(all(ps$references == "good"))
})

test_that("judgements are recorded on the run and surface in comparisons", {
  run <- dragon_run(copy_fixture_run())
  res <- dragonfarm:::judge_pairs(c("p1", "p2"), c("good", "good"), c("bad", "bad"), fake_pair_judge("good"))
  res$run <- run$id
  res$against <- "base"
  res$judged_at <- dragonfarm:::now_iso()
  res$judge <- "fake"
  class(res) <- "dragon_judgement"
  dragonfarm:::record_judgement(run, res)
  expect_true(file.exists(file.path(run$dir, "judge.json")))
  st <- dragon_status(run)
  expect_equal(st$judge$win_rate, 1)
  expect_equal(st$judge$against, "base")
  msgs <- testthat::capture_messages(print(res))
  expect_true(any(grepl("wins", msgs)))
  cmp <- dragon_compare(run)
  expect_equal(cmp$judge, 1)
  expect_equal(cmp$judge_n, 2L)
  dragonfarm:::record_judgement(run, res)
  expect_length(dragonfarm:::read_json(file.path(run$dir, "judge.json")), 2)
})

test_that("judging falls back to training prompts when nothing was held out", {
  # 10 pairs: 5% held out rounds to zero rows
  ds <- dragon_map_pairs(dragon_dataset(data.frame(q = paste("Q", 1:10), g = "good", b = "bad")), "q", "g", "b")
  run <- suppressMessages(dragon_bundle(ds, "HuggingFaceTB/SmolLM2-135M-Instruct", runs_dir = tempfile("runs-")))
  expect_length(dragonfarm:::eval_prompts(run, NULL, n = 5, seed = 1)$prompts, 0)
  tr <- dragonfarm:::eval_prompts(run, NULL, n = 5, seed = 1, split = "train")
  expect_length(tr$prompts, 5)
  expect_true(all(tr$references == "good"))
  rl <- suppressMessages(dragon_bundle(
    dragon_map_prompts(dragon_dataset(data.frame(q = paste("Q", 1:40), a = as.character(1:40))), "q", reference = "a"),
    "HuggingFaceTB/SmolLM2-135M-Instruct", runs_dir = tempfile("runs-"), rewards = dragon_reward("numeric")
  ))
  ev <- dragonfarm:::eval_prompts(rl, NULL, n = 5, seed = 1)
  expect_length(ev$prompts, 2)
  expect_false(any(is.na(ev$references)))
})


test_that("a judge or teacher saved for a background pipeline never carries an API key", {
  withr::local_envvar(ANTHROPIC_API_KEY = "sk-ant-FAKE-DETECTME", OPENROUTER_API_KEY = "sk-or-FAKE-DETECTME")
  leaks <- function(obj) length(grepRaw("DETECTME", serialize(obj, NULL), fixed = TRUE)) > 0
  j <- dragon_judge_anthropic()
  expect_false(leaks(j))
  expect_false(leaks(dragonfarm:::strip_handles(list(dragon_step_judge(against = "base", judge = j)))))
  expect_false(leaks(dragon_llm_anthropic(system = "x")))
  expect_false(leaks(dragonfarm:::llm_provider("openrouter", "m:free")))
  expect_true(leaks(dragon_llm_anthropic(api_key = "sk-ant-FAKE-DETECTME")))   # an explicit key is the caller's choice
})
