test_that("answers are split into checkable sentences; citations and declines are left out", {
  s <- dragonfarm:::answer_sentences(paste(
    "Returns are accepted within 30 days [1]. Refunds take 5 business days [2].",
    "The documents do not mention a restocking fee. Ok."))
  expect_equal(s, c("Returns are accepted within 30 days.", "Refunds take 5 business days."))
  expect_length(dragonfarm:::answer_sentences("The documents do not cover prices."), 0)
})

test_that("yes and no are read strictly", {
  expect_equal(dragonfarm:::yes_no(c("Yes.", "no", "  YES, it is", "Maybe", "Not sure")), c(TRUE, FALSE, TRUE, NA, NA))
})

test_that("faithfulness, precision and recall come from yes/no verdicts and a pattern", {
  hits <- data.frame(n = 1:3, text = c("Any device can be returned within 30 days.", "Shipping takes 3 to 5 days.",
                                       "Refunds take 5 business days."))
  answer <- list(question = "How long is the return window?", answer = "Returns are accepted within 30 days [1]. You also get a free gift.",
                 sources = hits)
  testthat::local_mocked_bindings(backend_generate = function(backend, target, conversations, ...) {
    lapply(conversations, function(cv) {
      p <- cv[[1]]$content
      if (grepl("^Excerpts", p)) if (grepl("free gift", p)) "No" else "Yes"
      else if (grepl("returned within 30 days", p)) "Yes" else "No"
    })
  }, resolve_target = function(model, ...) list(model = model))
  m <- dragonfarm:::rag_metrics(answer, backend = dragon_backend_local(), answer_pattern = "30 days")
  expect_equal(m$faithfulness, 0.5); expect_equal(m$unsupported, "You also get a free gift.")
  expect_equal(m$context_precision, 1)                  # the one helpful excerpt is first
  expect_true(m$context_recall)
  # helpful excerpt last: precision falls
  answer$sources <- hits[c(2, 3, 1), ]; answer$sources$n <- 1:3
  expect_equal(dragonfarm:::rag_metrics(answer, backend = dragon_backend_local())$context_precision, 1 / 3)
  expect_false(dragonfarm:::rag_context_recall(hits[2, ], "30 days"))
})

test_that("declines worded with an adverb or 'cannot determine' are not graded as claims", {
  s <- dragonfarm:::answer_sentences(paste(
    "The documents do not directly provide information about the founding year of the FDA.",
    "Therefore, we cannot determine how many patients were enrolled based on the given excerpts.",
    "The guidance recommends prespecifying the analysis."))
  expect_equal(s, "The guidance recommends prespecifying the analysis.")
})
