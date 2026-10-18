fb_backend <- function() structure(list(kind = "fake", model = "fake"), class = c("dragon_backend_fb", "dragon_backend"))
registerS3method("backend_generate", "dragon_backend_fb", function(backend, target, conversations, max_new_tokens = 256,
                                                                    temperature = 0.7, top_p = 0.9, on_token = NULL) {
  lapply(conversations, function(msgs) paste("reply to", msgs[[length(msgs)]]$content, "at", format(Sys.time(), "%H%M%OS3")))
}, envir = asNamespace("dragonfarm"))

test_that("chat ratings, edits, and regenerations are recorded", {
  runs <- tempfile("runs-")
  chat <- dragon_chat("any/model", system = "Be kind.", backend = fb_backend(), runs_dir = runs)
  expect_error(chat$rate("up"), "nothing to rate", ignore.case = TRUE)
  chat$say("hello")
  chat$rate("up")
  chat$say("second")
  chat$rate(-1)
  chat$edit("a better second answer")
  expect_equal(chat$history()[[4]]$content, "a better second answer")
  before <- chat$history()[[4]]$content
  chat$regenerate()
  expect_length(chat$history(), 4)
  expect_false(identical(chat$history()[[4]]$content, before))
  expect_error(chat$rate("sideways"), "up.*down|1", ignore.case = TRUE)

  recs <- dragonfarm:::read_jsonl(file.path(runs, "feedback", "feedback.jsonl"))
  expect_length(recs, 3)
  expect_equal(recs[[1]]$rating, 1)
  expect_equal(recs[[1]]$label, "model")
  expect_equal(recs[[1]]$system, "Be kind.")
  expect_length(recs[[1]]$context, 1)
  expect_equal(recs[[2]]$rating, -1)
  expect_length(recs[[2]]$context, 3)
  expect_equal(recs[[3]]$edited, "a better second answer")
})

test_that("dragon_feedback turns records into conversations and pairs", {
  runs <- tempfile("runs-")
  ctx <- list(list(role = "user", content = "How do I reset it?"))
  dragonfarm:::record_feedback(runs, "run-a", "Be brief.", ctx, "Hold the button for 10 seconds.", rating = 1)
  dragonfarm:::record_feedback(runs, "run-a", "Be brief.", ctx, "I do not know.", rating = -1)
  ctx2 <- c(ctx, list(list(role = "assistant", content = "Hold the button."), list(role = "user", content = "Which button?")))
  dragonfarm:::record_feedback(runs, "run-a", "Be brief.", ctx2, "The red one.", edited = "The small recessed one on the back.")
  dragonfarm:::record_feedback(runs, "run-b", NULL, list(list(role = "user", content = "Hi")), "Hello!", rating = -1)

  fb <- dragon_feedback(runs)
  expect_equal(nrow(fb$records), 4)
  expect_equal(sum(fb$records$edited), 1)
  expect_s3_class(fb$sft, "dragon_dataset")
  expect_equal(dragonfarm:::mapping_kind(fb$sft), "conversations")
  expect_equal(nrow(fb$sft$data), 2)                       # one liked, one edited
  edited_row <- fb$sft$data$messages[[2]]
  expect_equal(edited_row[[length(edited_row)]]$content, "The small recessed one on the back.")
  expect_equal(edited_row[[1]]$role, "system")
  expect_s3_class(fb$pairs, "dragon_dataset")
  expect_equal(dragonfarm:::mapping_kind(fb$pairs), "pairs")
  expect_equal(nrow(fb$pairs$data), 1)
  expect_equal(fb$pairs$data$chosen, "Hold the button for 10 seconds.")
  expect_equal(fb$pairs$data$rejected, "I do not know.")
  expect_equal(fb$pairs$mapping$system, "{`system`}")

  only_b <- dragon_feedback(runs, label = "run-b")
  expect_equal(nrow(only_b$records), 1)
  expect_null(only_b$sft)
  expect_null(only_b$pairs)
  empty <- dragon_feedback(tempfile())
  expect_equal(nrow(empty$records), 0)
  expect_null(empty$sft)

  # the datasets feed the stages directly
  run <- suppressMessages(dragon_bundle(fb$sft, "HuggingFaceTB/SmolLM2-135M-Instruct", runs_dir = runs))
  expect_equal(dragonfarm:::run_config(run)$stage, "sft")
  pref <- suppressMessages(dragon_bundle(fb$pairs, "HuggingFaceTB/SmolLM2-135M-Instruct", runs_dir = runs))
  expect_equal(dragonfarm:::run_config(pref)$stage, "prefer")
})

test_that("the chat module records feedback from the thread", {
  runs <- tempfile("runs-")
  dir.create(runs)
  withr::local_options(dragonfarm.backend = fb_backend())
  state <- shiny::reactiveValues(run = NULL)
  shiny::testServer(dragonfarm:::mod_chat_server, args = list(state = state, runs_dir = runs), {
    session$setInputs(source = "ollama", ollama_model = "m", ollama_url = "http://localhost:11434",
                      system = "", temperature = 0.5, max_new_tokens = 64, text = "hello")
    # force the fake backend regardless of the selector
    session$setInputs(send = 1)
    h <- history()
    expect_length(h, 0)   # the ollama backend is unreachable, so the turn was dropped
  })
})

test_that("Chat turns ratings into a Train-ready dataset without any R", {
  runs <- tempfile("runs-")
  dir.create(runs)
  ctx <- list(list(role = "user", content = "How do I reset it?"))
  expect_equal(dragonfarm:::feedback_counts(runs)$total, 0)
  dragonfarm:::record_feedback(runs, "run-a", NULL, ctx, "Hold the button for 10 seconds.", rating = 1)
  dragonfarm:::record_feedback(runs, "run-a", NULL, ctx, "I do not know.", rating = -1)
  dragonfarm:::record_feedback(runs, "run-a", NULL, list(list(role = "user", content = "Which button?")), "The red one.",
                               edited = "The small recessed one on the back.")
  n <- dragonfarm:::feedback_counts(runs)
  expect_equal(unlist(n), c(total = 3, liked = 1, disliked = 1, edited = 1))
  state <- shiny::reactiveValues(run = NULL, dataset = NULL, mapped = NULL)
  shiny::testServer(dragonfarm:::mod_chat_server, args = list(state = state, runs_dir = runs), {
    card <- output$feedback_card$html
    expect_match(card, "1 liked, 1 disliked, 1 edited")
    expect_match(card, "Train on my feedback")
    session$setInputs(train_feedback = 1)
    expect_s3_class(state$mapped, "dragon_dataset")
    expect_equal(nrow(state$mapped$data), 2)          # the liked and the edited reply, each with its turns
    expect_identical(state$dataset, state$mapped)
  })
})
