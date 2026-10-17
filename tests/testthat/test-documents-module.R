# The Documents panel without Python: opening a saved set, queuing pages,
# asking (mocked), handing off to Chat, and switching to the table route.

test_that("the documents module opens a saved set, asks, and switches routes", {
  runs_dir <- tempfile("runs-")
  f <- write_fake_set(root = runs_dir)
  state <- shiny::reactiveValues(documents = NULL, route = "documents", hardware = NULL)
  visited <- character()
  asked <- NULL
  testthat::local_mocked_bindings(
    worker_start = function(backend = NULL) invisible(NULL),
    dragon_index = function(docs, ...) docs,
    hardware_info = function() NULL,
    dragon_documents = function(paths, name = NULL, runs_dir = NULL, ...) {
      expect_true(dir.exists(paths)); expect_equal(name, "example-policies"); dragon_documents_load(f$dir)
    },
    dragon_ask = function(docs, question, model = NULL, k = 4, compare = FALSE, ...) {
      asked <<- list(docs = docs$name, question = question, model = model, k = k, compare = compare)
      structure(list(question = question, answer = "Thirty days [1].", model = "test-model", documents = docs$name,
                     sources = data.frame(n = 1L, id = "abc-000", source = "policy.pdf", section = "Returns",
                                          text = "Thirty days.", score = 0.9, similarity = 0.9, weight = 1, cited = TRUE,
                                          stringsAsFactors = FALSE)),
                class = "dragon_answer")
    }
  )
  shiny::testServer(dragonfarm:::mod_documents_server,
    args = list(state = state, nav_to = function(p) visited <<- c(visited, p), runs_dir = runs_dir), {
    session$flushReact()
    expect_null(state$documents)

    # queue a page (scheme added) and see it listed
    session$setInputs(url = "example.com/faq")
    session$setInputs(add_url = 1)
    expect_equal(pending_urls(), "https://example.com/faq")
    expect_match(output$pending$html, "https://example.com/faq")

    # asking before any set is loaded is refused politely
    session$setInputs(question = "How long?", k = 4, model = "")
    session$setInputs(ask = 1)
    expect_null(asked)

    # open the saved set
    session$setInputs(saved = f$dir)
    expect_s3_class(state$documents, "dragon_documents")
    expect_equal(state$documents$name, "kb")
    expect_match(output$summary$html, "policy.pdf")
    expect_match(output$summary$html, "changelog, down-weighted")

    session$setInputs(ask = 2)
    expect_equal(asked$question, "How long?")
    expect_equal(asked$docs, "kb")
    expect_null(asked$model)
    expect_false(asked$compare)                 # off unless ticked
    html <- output$answer$html
    expect_match(html, "Thirty days \\[1\\]")
    expect_match(html, "policy.pdf")
    expect_match(html, "<strong>")   # the cited source is bold
    session$setInputs(compare = TRUE, ask = 3)
    expect_true(asked$compare)                  # "Look for documents that disagree" reaches dragon_ask()

    session$setInputs(example = 1)
    expect_equal(state$documents$name, "kb")

    session$setInputs(to_chat = 1)
    expect_equal(visited, "chat")
    session$setInputs(table_route = 1)
    expect_equal(state$route, "table")
    expect_equal(visited, c("chat", "data"))
  })
})

test_that("the app builds for both routes", {
  expect_s3_class(dragon_app(runs_dir = tempfile("runs-")), "shiny.appobj")
  expect_s3_class(dragon_app(runs_dir = tempfile("runs-"), route = "table"), "shiny.appobj")
  expect_error(dragon_app(runs_dir = tempfile("runs-"), route = "pdf"))
  titles <- dragonfarm:::route_titles("documents")
  expect_equal(titles[["documents"]], "1 Documents")
  expect_equal(titles[["pipeline"]], "7 Pipeline")
  titles <- dragonfarm:::route_titles("table")
  expect_equal(titles[["data"]], "1 Data")
  expect_equal(titles[["model"]], "3 Model")
  expect_equal(titles[["pipeline"]], "8 Pipeline")
})

test_that("the Teach card reviews a question set and hands a dataset to Model", {
  runs_dir <- tempfile("runs-")
  f <- write_fake_set(root = runs_dir)
  qpath <- write_fake_questions(f$dir)
  state <- shiny::reactiveValues(documents = dragon_documents_load(f$dir), route = "documents", hardware = NULL,
                                 dataset = NULL, mapped = NULL)
  visited <- character()
  testthat::local_mocked_bindings(
    worker_start = function(backend = NULL) invisible(NULL), dragon_index = function(docs, ...) docs, hardware_info = function() NULL,
    dragon_retrieve = function(docs, query, k = 4, ...) do.call(rbind, lapply(query, function(q) data.frame(
    query = q, n = 1L, id = "abc-000", source = "policy.pdf", section = "Returns", text = "Thirty days.",
    score = 0.9, similarity = 0.9, weight = 1, stringsAsFactors = FALSE))))
  shiny::testServer(dragonfarm:::mod_documents_server,
    args = list(state = state, nav_to = function(p) visited <<- c(visited, p), runs_dir = runs_dir), {
    session$flushReact()
    session$setInputs(qset = qpath)
    qa <- questions()
    expect_s3_class(qa, "dragon_questions")
    html <- output$review$html
    expect_match(html, "2 of 3 kept")
    expect_match(html, "refers to the passage")
    expect_match(html, "policy.pdf . Returns")

    # untick the kept warranty pair, rescue the rejected one, save
    session$setInputs(`keep_abc-000` = c("p0001", "p0002"), `keep_abc-001` = character())
    session$setInputs(save_review = 1)
    saved <- dragon_questions_load(qpath)
    expect_equal(saved$keep, c(TRUE, TRUE, FALSE))

    session$setInputs(to_model = 1)
    expect_s3_class(state$mapped, "dragon_dataset")
    expect_equal(nrow(state$mapped$data), 2L)
    expect_equal(visited, "model")
  })
})

test_that("Read and index with nothing queued explains a still-running upload", {
  runs_dir <- tempfile("runs-")
  state <- shiny::reactiveValues(documents = NULL, route = "documents", hardware = NULL)
  notes <- character()
  testthat::local_mocked_bindings(
    showNotification = function(ui, ...) { notes <<- c(notes, paste(ui, collapse = " ")); invisible("id") },
    .package = "shiny"
  )
  testthat::local_mocked_bindings(dragon_documents = function(...) stop("must not be called"))
  shiny::testServer(dragonfarm:::mod_documents_server,
    args = list(state = state, nav_to = function(p) NULL, runs_dir = runs_dir), {
    session$setInputs(name = "my-docs", build = 1)
    expect_true(any(grepl("still uploading", notes)))
    expect_null(state$documents)
  })
})

test_that("the training-rows message counts 'not covered' examples", {
  d <- data.frame(question = letters[1:5], negative = c(FALSE, FALSE, FALSE, FALSE, TRUE))
  expect_equal(dragonfarm:::training_rows_message(d),
               "5 training rows ready (4 questions and 1 'not covered' example). Pick a model next.")
  expect_equal(dragonfarm:::training_rows_message(d[1:4, ]), "4 training rows ready. Pick a model next.")
  expect_equal(dragonfarm:::training_rows_message(data.frame(question = "a")), "1 training rows ready. Pick a model next.")
})

test_that("Write practice questions passes the mix checkbox to dragon_questions()", {
  runs_dir <- tempfile("runs-")
  f <- write_fake_set(root = runs_dir)
  state <- shiny::reactiveValues(documents = dragon_documents_load(f$dir), route = "documents", hardware = NULL,
                                 dataset = NULL, mapped = NULL)
  got <- list()
  testthat::local_mocked_bindings(
    worker_start = function(backend = NULL) invisible(NULL), dragon_index = function(docs, ...) docs, hardware_info = function() NULL,
    dragon_questions = function(docs, generator = NULL, n_per_chunk = 3, mix = TRUE, ...) {
      got[[length(got) + 1]] <<- list(mix = mix, n = n_per_chunk)
      NULL
    }
  )
  shiny::testServer(dragonfarm:::mod_documents_server,
    args = list(state = state, nav_to = function(p) NULL, runs_dir = runs_dir), {
    session$flushReact()
    session$setInputs(generator = "", per_chunk = 3, generate = 1)
    session$setInputs(mix = FALSE, generate = 2)
    session$setInputs(mix = TRUE, generate = 3)
  })
  expect_equal(vapply(got, `[[`, NA, "mix"), c(TRUE, FALSE, TRUE))   # on by default
})
