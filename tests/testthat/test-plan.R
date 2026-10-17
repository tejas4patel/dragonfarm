plan_dataset <- function() {
  dragon_dataset(dragon_example_data()) |> dragon_map(prompt = "{subject}\n\n{body}", response = "reply")
}

claude_like <- function() structure(function(prompts, schema = NULL) "", label = "anthropic:claude-sonnet-5")

test_that("judges say where they run and whether data leaves the machine", {
  local <- dragonfarm:::judge_place("Qwen/Qwen2.5-7B-Instruct")
  expect_true(local$gpu); expect_true(is.na(local$leaves))
  expect_match(dragonfarm:::judge_place(claude_like())$leaves, "Anthropic")
  expect_match(dragonfarm:::judge_place(function(p) p)$leaves, "your own function")
})

test_that("the plan lists every step, the GPU, what leaves, and past timings", {
  runs <- withr::local_tempdir()
  dir.create(file.path(runs, "pipelines"))
  jsonlite::write_json(list(model = "m", steps = list(
    list(type = "train", state = "succeeded", started_at = "2026-10-17T10:00:00Z", finished_at = "2026-10-17T10:10:00Z"),
    list(type = "judge", state = "failed", started_at = "2026-10-17T10:10:00Z", finished_at = "2026-10-17T10:11:00Z")
  )), file.path(runs, "pipelines", "old.json"), auto_unbox = TRUE)
  steps <- list(dragon_step_train(plan_dataset()),
                dragon_step_synthesize_pairs(n = 10, judge = claude_like()),
                dragon_step_prefer(),
                dragon_step_judge(judge = "Qwen/Qwen2.5-7B-Instruct", n = 4),
                dragon_step_publish("me/model", private = TRUE))
  pl <- dragonfarm:::pipeline_plan("m", steps, runs_dir = runs)
  expect_equal(pl$step, c("train", "synthesize_pairs", "prefer", "judge", "publish"))
  expect_equal(pl$estimate_s, c(600, NA, NA, NA, NA))            # a failed step is no estimate
  expect_equal(pl$gpu, c(TRUE, TRUE, TRUE, TRUE, FALSE))
  expect_match(pl$leaves[2], "Anthropic"); expect_true(is.na(pl$leaves[4])); expect_match(pl$leaves[5], "Hugging Face.*private")
  expect_equal(nrow(dragonfarm:::pipeline_plan("other-model", steps[1], runs_dir = runs)[!is.na(dragonfarm:::pipeline_plan("other-model", steps[1], runs_dir = runs)$estimate_s), ]), 0)

  html <- as.character(dragonfarm:::plan_ui(pl))
  expect_match(html, "about 10 min")
  expect_match(html, "no estimate yet")
  expect_match(html, "sends data to Anthropic")
  local_only <- as.character(dragonfarm:::plan_ui(pl[c(1, 3), ]))
  expect_match(local_only, "Nothing leaves this machine")
})

test_that("starting from a plan records the approval with the plan", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  pl <- dragonfarm:::pipeline_plan("m", list(dragon_step_train(plan_dataset())), runs_dir = runs)
  dragonfarm:::plan_record_approval("pipeline x", pl, runs_dir = runs)
  ev <- dragonfarm:::store_events(1, runs_dir = runs)
  expect_equal(ev$kind, "approval")
  expect_match(ev$detail, "Fine-tune on")
})

test_that("durations read plainly", {
  f <- dragonfarm:::format_duration
  expect_equal(f(NA), "no estimate yet"); expect_equal(f(40), "about 40 s")
  expect_equal(f(600), "about 10 min"); expect_equal(f(3 * 3600), "about 3.0 h")
})
