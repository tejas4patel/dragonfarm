# dragon_ask(), dragon_retrieve() shaping, and chat-with-documents, with the
# worker and backend mocked. The real path runs under DRAGONFARM_INTEGRATION=true.

fake_hits <- function(n = 3) {
  data.frame(
    n = seq_len(n), id = sprintf("abc-%03d", seq_len(n) - 1), source = c("policy.pdf", "policy.pdf", "NEWS.md")[seq_len(n)],
    section = c("Returns", "Warranty", "1.1.0")[seq_len(n)],
    text = c("Any device can be returned within 30 days.", "Every device has a 2-year warranty.", "Changed things.")[seq_len(n)],
    score = c(0.8, 0.6, 0.4)[seq_len(n)], similarity = c(0.8, 0.6, 0.57)[seq_len(n)], weight = c(1, 1, 0.7)[seq_len(n)],
    stringsAsFactors = FALSE
  )
}

test_that("the documents prompt numbers excerpts and the parser reads citations back", {
  p <- dragonfarm:::documents_prompt("How long is the return window?", fake_hits())
  expect_match(p, "\\[1\\] policy.pdf . Returns\nAny device can be returned within 30 days.", perl = TRUE)
  expect_match(p, "\\[3\\] NEWS.md . 1.1.0")
  expect_match(p, "Question: How long is the return window\\?$")
  expect_match(dragonfarm:::documents_prompt("q", fake_hits(0)), "No excerpts were found")

  expect_equal(dragonfarm:::parse_citations("Thirty days [1]. Also [1, 3] and [2][3].", 3), 1:3)
  expect_equal(dragonfarm:::parse_citations("Thirty days [1]. See [9].", 3), 1L)
  expect_equal(dragonfarm:::parse_citations("No citations here.", 3), integer())
  expect_equal(dragonfarm:::parse_citations("", 3), integer())
  expect_match(dragonfarm:::documents_system(), "only the numbered excerpts")
  expect_match(dragonfarm:::documents_system("Answer in French."), "Answer in French\\.$")
})

test_that("models of 3B and up are asked for full answers, smaller ones for short ones", {
  full <- dragonfarm:::full_answers_for
  expect_true(full(list(model = "Qwen/Qwen2.5-7B-Instruct")))
  expect_true(full(list(model = "Qwen/Qwen2.5-3B-Instruct")))
  expect_false(full(list(model = "Qwen/Qwen2.5-1.5B-Instruct")))
  expect_false(full(list(model = "Qwen/Qwen2.5-0.5B-Instruct", adapter = "some/adapter")))
  expect_true(full(list(model = "org/no-size")))
  expect_true(full(NULL))
  long <- dragonfarm:::documents_system(full = TRUE)
  short <- dragonfarm:::documents_system(full = FALSE)
  expect_match(long, "Answer the question fully", fixed = TRUE)
  expect_false(grepl("Be concise", long, fixed = TRUE))
  expect_match(short, "Be concise.$")
  expect_match(dragonfarm:::documents_system(full = FALSE, small = TRUE), "do not cover this\\.\"$")
})

test_that("dragon_ask retrieves, asks the backend with the excerpts, and marks cited sources", {
  f <- write_fake_set()
  docs <- dragon_documents_load(f$dir)
  seen <- NULL
  testthat::local_mocked_bindings(
    dragon_retrieve = function(docs, query, k = 4, ...) fake_hits(),
    default_answer_model = function() "Qwen/Qwen2.5-1.5B-Instruct",
    worker_start = function(backend = NULL) invisible(NULL),
    worker_request = function(req, on_token = NULL, timeout = 3600) {
      seen <<- req
      list(outputs = list("You can return it within 30 days [1]. The warranty is two years [2]."))
    }
  )
  ans <- dragon_ask(docs, "How long is the return window?")
  expect_s3_class(ans, "dragon_answer")
  expect_equal(ans$model, "Qwen/Qwen2.5-1.5B-Instruct")
  expect_equal(seen$model, "Qwen/Qwen2.5-1.5B-Instruct")
  expect_equal(seen$temperature, 0)
  expect_equal(seen$conversations[[1]][[1]]$role, "system")
  expect_match(seen$conversations[[1]][[2]]$content, "\\[2\\] policy.pdf . Warranty")
  expect_equal(ans$sources$cited, c(TRUE, TRUE, FALSE))
  out <- capture.output(print(ans))
  expect_true(any(grepl("^\\[1\\]\\* policy.pdf", out)))
  expect_true(any(grepl("^\\[3\\]  NEWS.md", out)))

  ans2 <- dragon_ask(docs, "q", model = "my/model", system = "Answer in French.")
  expect_equal(seen$model, "my/model")
  expect_match(seen$conversations[[1]][[1]]$content, "Answer in French")
  expect_error(dragon_ask(docs, ""), "question")
  expect_error(dragon_ask(docs, "q", backend = "nope"), "backend")
})

test_that("dragon_retrieve shapes worker hits into a data frame", {
  f <- write_fake_set()
  docs <- dragon_documents_load(f$dir)
  docs$manifest$index <- list(model = "stub")   # pretend it is indexed
  testthat::local_mocked_bindings(
    worker_start = function(backend = NULL) invisible(NULL),
    worker_request = function(req, on_token = NULL, timeout = 3600) {
      expect_equal(req$op, "retrieve"); expect_equal(req$k, 2L)
      list(hits = lapply(req$queries, function(q) list(list(id = "abc-001", score = 0.9, similarity = 0.9),
                                                       list(id = "def-000", score = 0.35, similarity = 0.5))))
    }
  )
  h <- dragon_retrieve(docs, "warranty", k = 2)
  expect_equal(h$n, 1:2)
  expect_equal(h$section, c("Warranty", "1.1.0"))
  expect_equal(h$weight, c(1, 0.7))
  expect_null(h$query)
  h2 <- dragon_retrieve(docs, c("a", "b"), k = 2)
  expect_equal(nrow(h2), 4L)
  expect_equal(unique(h2$query), c("a", "b"))
  expect_error(dragon_retrieve(docs, character()), "query")
  expect_error(dragon_retrieve(docs, "q", extra = -1), "extra")
})

test_that("compare asks for two different extra excerpts and for each document's version", {
  f <- write_fake_set()
  docs <- dragon_documents_load(f$dir)
  extras <- integer(); systems <- character()
  testthat::local_mocked_bindings(
    dragon_retrieve = function(docs, query, k = 4, extra = 0) { extras <<- c(extras, extra); fake_hits() },
    worker_start = function(backend = NULL) invisible(NULL),
    worker_request = function(req, on_token = NULL, timeout = 3600) {
      systems <<- c(systems, req$conversations[[1]][[1]]$content)
      list(outputs = list("Thirty days [1]."))
    }
  )
  dragon_ask(docs, "How long is the return window?", model = "Qwen/Qwen2.5-7B-Instruct")
  dragon_ask(docs, "How long is the return window?", model = "Qwen/Qwen2.5-7B-Instruct", compare = TRUE)
  expect_equal(extras, c(0L, 2L))
  expect_false(grepl("disagree", systems[1]))
  expect_match(systems[2], "If they disagree, say so")
})

test_that("a chat with documents sends excerpts to the model but keeps plain history", {
  f <- write_fake_set()
  docs <- dragon_documents_load(f$dir)
  sent <- list()
  testthat::local_mocked_bindings(
    dragon_retrieve = function(docs, query, k = 4, ...) fake_hits(2),
    default_answer_model = function() "Qwen/Qwen2.5-1.5B-Instruct",
    worker_start = function(backend = NULL) invisible(NULL),
    worker_request = function(req, on_token = NULL, timeout = 3600) {
      sent[[length(sent) + 1]] <<- req$conversations[[1]]
      list(outputs = list("Thirty days [1]."))
    }
  )
  ch <- dragon_chat(documents = docs)          # no x: falls back to the recommended model
  ch$say("How long is the return window?")
  convo <- sent[[1]]
  expect_equal(convo[[1]]$role, "system")
  expect_match(convo[[1]]$content, "numbered excerpts")
  expect_match(convo[[2]]$content, "\\[1\\] policy.pdf")
  expect_equal(ch$history()[[1]]$content, "How long is the return window?")   # plain, not the wrapped prompt
  expect_equal(ch$sources()$cited, c(TRUE, FALSE))
  ch$say("And the warranty?")
  convo2 <- sent[[2]]
  expect_equal(convo2[[2]]$content, "How long is the return window?")   # earlier turns stay plain in the context
  expect_match(convo2[[4]]$content, "Question: And the warranty\\?$")
})

test_that("a short follow-up is also searched with the question before it", {
  lean <- dragonfarm:::leans_on_previous
  expect_true(lean("And a boxplot?"))
  expect_true(lean("Which ones, then?"))
  expect_true(lean("How do I load it?"))
  expect_false(lean("How do I quit an R session?"))
  expect_false(lean("Which standard error does FDA suggest for a linear model without treatment-by-covariate interactions and why is it preferred?"))
  f <- write_fake_set()
  docs <- dragon_documents_load(f$dir)
  queries <- character()
  testthat::local_mocked_bindings(
    dragon_retrieve = function(docs, query, k = 4, ...) {
      queries <<- c(queries, query)
      h <- fake_hits(3)
      if (grepl("return window", query)) h$id <- c("abc-000", "abc-007", "abc-008")
      h
    },
    default_answer_model = function() "Qwen/Qwen2.5-1.5B-Instruct",
    worker_start = function(backend = NULL) invisible(NULL),
    worker_request = function(req, on_token = NULL, timeout = 3600) list(outputs = list("Thirty days [1]."))
  )
  ch <- dragon_chat(documents = docs, k = 3)
  ch$say("How long is the return window?")
  expect_equal(queries, "How long is the return window?")
  ch$say("And does it cover opened boxes?")
  expect_equal(queries[2:3], c("And does it cover opened boxes?", "How long is the return window? And does it cover opened boxes?"))
  # its own best two excerpts, then the best one the joined search adds
  expect_equal(ch$sources()$id, c("abc-000", "abc-001", "abc-007"))
  expect_equal(ch$sources()$n, 1:3)
  ch$say("Which device has the longest warranty of all the ones you sell?")
  expect_length(queries, 4)          # a full question is searched on its own
})

test_that("documents are indexed and asked for real", {
  skip_if_not(identical(Sys.getenv("DRAGONFARM_INTEGRATION"), "true"), "set DRAGONFARM_INTEGRATION=true")
  skip_on_cran()
  src <- tempfile("src-"); dir.create(src)
  writeLines(c("# Returns", "", paste(rep("Any device can be returned within 30 days of delivery for a full refund.", 6), collapse = " "),
               "", "# Warranty", "", paste(rep("Every device carries a 2-year limited warranty counted from the delivery date.", 6), collapse = " "),
               "", "# Wi-Fi", "", paste(rep("Wi-Fi drops come from band steering on mesh routers; use the 2.4 GHz band.", 6), collapse = " ")),
             file.path(src, "policy.md"))
  runs_dir <- tempfile("runs-")
  docs <- dragon_documents(src, name = "ask-test", runs_dir = runs_dir)
  expect_false(is.null(docs$manifest$index))
  h <- dragon_retrieve(docs, "How long is the warranty?", k = 2)
  expect_equal(h$section[1], "Warranty")
  ans <- dragon_ask(docs, "How long is the warranty?", model = "HuggingFaceTB/SmolLM2-135M-Instruct", k = 2, max_new_tokens = 40)
  expect_true(nzchar(ans$answer))
  expect_equal(nrow(ans$sources), 2L)
  dragon_worker_stop()
})

test_that("a reply that is only a citation is asked again once", {
  expect_true(dragonfarm:::citation_only("[1]"))
  expect_true(dragonfarm:::citation_only("[1], [2]"))
  expect_true(dragonfarm:::citation_only(""))
  expect_false(dragonfarm:::citation_only("Thirty days [1]."))
  expect_false(dragonfarm:::citation_only("2 years [2]"))
  expect_true(dragonfarm:::citation_only("[R-admin.pdf, p. 28 › 6 Add-on packages]"))   # an echoed source label
  expect_false(dragonfarm:::citation_only("Set R_LIBS_USER [1]."))
  expect_false(dragonfarm:::citation_only("[R_LIBS_USER]"))       # an answer in brackets
  expect_true(dragonfarm:::citation_only("[1, 3]"))
  expect_true(dragonfarm:::citation_only("[policy.pdf > Returns]"))

  f <- write_fake_set()
  docs <- dragon_documents_load(f$dir)
  replies <- list("[1]", "You can return it within 30 days [1].")
  seen <- list()
  testthat::local_mocked_bindings(
    dragon_retrieve = function(docs, query, k = 4, ...) fake_hits(),
    default_answer_model = function() "Qwen/Qwen2.5-3B-Instruct",
    worker_start = function(backend = NULL) invisible(NULL),
    worker_request = function(req, on_token = NULL, timeout = 3600) {
      seen[[length(seen) + 1]] <<- req
      out <- replies[[1]]; replies <<- replies[-1]
      list(outputs = list(out))
    }
  )
  ans <- dragon_ask(docs, "How long is the return window?")
  expect_equal(ans$answer, "You can return it within 30 days [1].")
  expect_length(seen, 2)
  retry <- seen[[2]]$conversations[[1]]
  expect_equal(vapply(retry, `[[`, "", "role"), c("system", "user", "assistant", "user"))
  expect_equal(retry[[3]]$content, "[1]")
  expect_equal(ans$sources$cited, c(TRUE, FALSE, FALSE))

  # Two citation-only replies: one plain attempt with just the cited excerpt;
  # if that is only brackets too, the first reply stays, and nothing loops.
  replies <- list("[2]", "[1]", "[2]")
  seen <- list()
  ans2 <- dragon_ask(docs, "q")
  expect_equal(ans2$answer, "[2]")
  expect_length(seen, 3)
  plain <- seen[[3]]$conversations[[1]]
  expect_equal(vapply(plain, `[[`, "", "role"), "user")
  expect_match(plain[[1]]$content, "2-year warranty", fixed = TRUE)
  expect_false(grepl("30 days", plain[[1]]$content, fixed = TRUE))   # only the cited excerpt

  replies <- list("[2]", "[2]", "Every device has a 2-year warranty.")
  ans3 <- dragon_ask(docs, "How long is the warranty?")
  expect_equal(ans3$answer, "Every device has a 2-year warranty. [2]")
  expect_equal(ans3$sources$cited, c(FALSE, TRUE, FALSE))
  replies <- list("[1]", "[1]", "The documents do not cover this.")
  expect_equal(dragon_ask(docs, "q")$answer, "The documents do not cover this.")   # a decline is not cited

  # A normal reply is not asked again.
  replies <- list("Two years [2].")
  seen <- list()
  dragon_ask(docs, "q")
  expect_length(seen, 1)
})

test_that("a chat with documents asks again once when the reply is only a citation", {
  f <- write_fake_set()
  docs <- dragon_documents_load(f$dir)
  replies <- list("[1]", "Thirty days [1].")
  sent <- list()
  testthat::local_mocked_bindings(
    dragon_retrieve = function(docs, query, k = 4, ...) fake_hits(2),
    default_answer_model = function() "Qwen/Qwen2.5-3B-Instruct",
    worker_start = function(backend = NULL) invisible(NULL),
    worker_request = function(req, on_token = NULL, timeout = 3600) {
      sent[[length(sent) + 1]] <<- req$conversations[[1]]
      out <- replies[[1]]; replies <<- replies[-1]
      list(outputs = list(out))
    }
  )
  ch <- dragon_chat(documents = docs)
  reply <- ch$say("How long is the return window?")
  expect_equal(reply, "Thirty days [1].")
  expect_length(sent, 2)
  expect_equal(sent[[2]][[length(sent[[2]])]]$role, "user")
  h <- ch$history()
  expect_length(h, 2)                                   # the retry is not kept in the history
  expect_equal(h[[2]]$content, "Thirty days [1].")
  expect_equal(ch$sources()$cited, c(TRUE, FALSE))
})

test_that("untrained models under 3B get an explicit 'not covered' line; others do not", {
  expect_true(dragonfarm:::decline_note_for(list(model = "Qwen/Qwen2.5-1.5B-Instruct")))
  expect_true(dragonfarm:::decline_note_for(list(model = "Qwen/Qwen2.5-0.5B-Instruct")))
  expect_false(dragonfarm:::decline_note_for(list(model = "Qwen/Qwen2.5-3B-Instruct")))
  expect_false(dragonfarm:::decline_note_for(list(model = "Qwen/Qwen2.5-7B-Instruct")))
  expect_false(dragonfarm:::decline_note_for(list(model = "Qwen/Qwen2.5-0.5B-Instruct", adapter = "/runs/x/adapter")))
  expect_false(dragonfarm:::decline_note_for(list(model = "org/model-name")))
  expect_false(dragonfarm:::decline_note_for(NULL))

  f <- write_fake_set()
  docs <- dragon_documents_load(f$dir)
  seen <- NULL
  testthat::local_mocked_bindings(
    dragon_retrieve = function(docs, query, k = 4, ...) fake_hits(),
    worker_start = function(backend = NULL) invisible(NULL),
    worker_request = function(req, on_token = NULL, timeout = 3600) {
      seen <<- req$conversations[[1]][[1]]$content
      list(outputs = list("Thirty days [1]."))
    }
  )
  dragon_ask(docs, "q", model = "Qwen/Qwen2.5-1.5B-Instruct", system = "Answer in French.")
  expect_true(endsWith(seen, 'Answer in French. If no excerpt states the answer, reply only: "The documents do not cover this."'))
  dragon_ask(docs, "q", model = "Qwen/Qwen2.5-7B-Instruct")
  expect_no_match(seen, "reply only")
  ch <- dragon_chat("Qwen/Qwen2.5-0.5B-Instruct", documents = docs)
  ch$say("q")
  expect_match(seen, "reply only")
})

test_that("model replies render as Markdown, but cannot add markup of their own", {
  h <- function(x) as.character(dragonfarm:::md_html(x))
  expect_match(h("**Check the machine** first.\n\n1. one\n2. two"), "<strong>Check the machine</strong>", fixed = TRUE)
  expect_match(h("1. one\n2. two"), "<ol>", fixed = TRUE)
  out <- h("Hi <script>alert(1)</script> and <b>bold</b>")
  expect_false(grepl("<script>", out, fixed = TRUE))
  expect_false(grepl("<b>", out, fixed = TRUE))
  expect_match(out, "&lt;script&gt;", fixed = TRUE)
  expect_match(h("Use `x <- 1` here."), "<code>x &lt;- 1</code>", fixed = TRUE)
  expect_match(h("```r\nif (a < b) x\n```"), "if (a &lt; b) x", fixed = TRUE)
  expect_match(h("[bad](javascript:alert(1)) [good](https://dragonfarm.dev)"), "href=\"#\"", fixed = TRUE)
  expect_match(h("[good](https://dragonfarm.dev)"), "href=\"https://dragonfarm.dev\"", fixed = TRUE)
  expect_false(grepl("<img", h("![x](https://example.com/t.png)"), fixed = TRUE))
  expect_equal(h(NULL), "")
})

test_that("dragon_ask streams the answer to on_token as it is written", {
  f <- write_fake_set()
  docs <- dragon_documents_load(f$dir)
  testthat::local_mocked_bindings(
    dragon_retrieve = function(docs, query, k = 4, ...) fake_hits(),
    default_answer_model = function() "Qwen/Qwen2.5-7B-Instruct",
    worker_start = function(backend = NULL) invisible(NULL),
    worker_request = function(req, on_token = NULL, timeout = 3600) {
      for (p in c("Thirty ", "days ", "[1].")) if (is.function(on_token)) on_token(p)
      list(output = "Thirty days [1].", outputs = list("Thirty days [1]."))
    }
  )
  pieces <- character()
  ans <- dragon_ask(docs, "How long is the return window?", on_token = function(p) pieces <<- c(pieces, p))
  expect_equal(paste(pieces, collapse = ""), "Thirty days [1].")
  expect_equal(ans$answer, "Thirty days [1].")
  expect_silent(dragon_ask(docs, "How long?"))      # no on_token: nothing streamed, nothing breaks
})
