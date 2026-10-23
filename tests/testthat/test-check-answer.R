# The model-free answer check: citations point at given excerpts, figures
# come from the cited excerpts or the question. Cases below are real 1.5B
# and 3B answers on the FDA set.

src <- data.frame(n = 1:2, text = c(
  "Without adjustment, the chance of at least one false positive is about 22% for ten independent endpoints and 7% for three.",
  "In Table 1, the odds ratio within each biomarker subgroup is 8.0; the unconditional odds ratio is 4.8."
))

test_that("citations and figures are read from an answer", {
  ca <- dragonfarm:::answer_citations
  expect_equal(ca("A [1], B [2, 3] and C [4-5][1]."), 1:5)
  expect_equal(ca("No citations."), integer())
  af <- dragonfarm:::answer_figures
  expect_equal(af("About 1,200 people [1], version 4.12.2, 22% in 2021."), c("1200", "4.12.2", "22", "2021"))
  expect_equal(af("One of 3 options [2]."), character())          # single digits are not checked
})

test_that("an answer whose figures come from its excerpts passes", {
  r <- dragonfarm:::answer_check("Within each subgroup the odds ratio is 8.0 [2].", src)
  expect_true(r$ok)
  expect_equal(r$citations, 2L)
})

test_that("a figure in no excerpt is caught", {
  # A 1.5B's answer; the benchmark grader passed it because 8.0 is there too.
  r <- dragonfarm:::answer_check("[2] Biomarker- positive: 8.0\n[Biomarker- negative]: 4.0", src)
  expect_false(r$ok)
  expect_equal(r$ungrounded, "4.0")
})

test_that("a share written as a decimal or a percentage counts as the same figure", {
  expect_true(dragonfarm:::answer_check("0.22", src[1, ])$ok)
  expect_true(dragonfarm:::answer_check("About 7%, or approximately 0.07. [1]", src)$ok)
  expect_false(dragonfarm:::answer_check("About 0.25 [1].", src)$ok)
})

test_that("citations to excerpts that were not given are caught", {
  r <- dragonfarm:::answer_check("It is 22% [3].", src)
  expect_false(r$ok)
  expect_equal(r$bad_citations, 3L)
})

test_that("figures in the question count as given", {
  q <- "What is the PDUFA fee for fiscal year 2025?"
  expect_true(dragonfarm:::answer_check("The documents do not cover the fee for 2025.", src, q)$ok)
  expect_false(dragonfarm:::answer_check("The documents do not cover the fee for 2025.", src)$ok)
})

test_that("the app shows one plain line only when the check fails", {
  expect_null(dragonfarm:::check_note(list(answer = "It is 8.0 [2].", sources = src, question = "")))
  note <- as.character(dragonfarm:::check_note(list(answer = "It is 4.0 [2] or 9.9 [5].", sources = src, question = "")))
  expect_match(note, "Check this: 4.0, 9.9 are not in the excerpts; [5] points to no excerpt.", fixed = TRUE)
})

test_that("check_answer is a tool that reads the excerpts from the set by id", {
  f <- write_fake_set()
  withr::local_options(dragonfarm.runs_dir = f$root)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  r <- dragonfarm:::tool_call("check_answer", list(set = f$dir, answer = "Returns within 30 days [1].",
                                                    sources = list(list(n = 1, id = "abc-000"))))
  expect_true(r$ok)
  expect_false(r$result$ok)
  expect_equal(unlist(r$result$ungrounded), "30")
  r2 <- dragonfarm:::tool_call("check_answer", list(set = f$dir, answer = "Thirty days [1]."))
  expect_equal(r2$code, "INVALID_ARGUMENTS")
})

test_that("a decline is the model speaking about its sources, not a quotation or any 'does not'", {
  d <- dragonfarm:::answer_declines
  expect_true(d("The documents do not cover this."))
  expect_true(d("The provided excerpts do not mention the enrolment count."))
  expect_true(d("I cannot answer that."))                               # short, no source named
  expect_true(d("None of the passages found mention ggplot2."))
  # A 3B on the NCHS documents (2026-10-22): declined, with an adjective in the way.
  expect_true(d("Based on the information provided in the documents, there is no specific mention of the MEC examination response rate for NHANES 2021-2023."))
  # From 30 graded FDA answers: full, correct answers that used to count as declines.
  expect_false(d(paste("FDA suggests the Huber-White sandwich standard error [1], which states that sponsors should consider",
                       "a robust standard error method when the model does not include treatment by covariate interactions.",
                       "This applies to linear models fitted to continuous outcomes in randomised trials.")))
  expect_false(d(paste("[1] states that \"This guidance does not address use of covariates to control for confounding in",
                       "non-randomized trials\". Covariate adjustment is recommended for prognostic baseline covariates [2].",
                       "Sponsors should prespecify the covariates and the model before unblinding the data.")))
  expect_false(d(""))
  expect_false(d(NA_character_))
})
