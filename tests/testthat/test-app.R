test_that("chips become templates", {
  expect_equal(dragonfarm:::chips_to_template(c("subject", "body")), "{subject}\\n\\n{body}")
  expect_equal(dragonfarm:::chips_to_template(character()), "")
  expect_equal(dragonfarm:::chips_to_template(NULL), "")
})

test_that("the mapping module produces a mapped dataset", {
  state <- shiny::reactiveValues(dataset = dragon_dataset(toy_df(5)), mapped = NULL)
  shiny::testServer(dragonfarm:::mod_mapping_server, args = list(state = state, nav_to = function(p) NULL), {
    session$setInputs(prompt_tpl = "{subject}\\n\\n{body}", response_tpl = "reply", system_tpl = "")
    m <- mapped()
    expect_s3_class(m, "dragon_dataset")
    expect_equal(m$mapping$prompt, "{subject}\n\n{body}")
    session$flushReact()
    expect_s3_class(state$mapped, "dragon_dataset")

    session$setInputs(prompt_tpl = "{nope}")
    expect_s3_class(mapped(), "mapping_error")
    session$flushReact()
    expect_null(state$mapped)

    session$setInputs(prompt_tpl = "")
    expect_null(mapped())
  })
})

test_that("an already-mapped dataset passes through the mapping module untouched", {
  ds <- dragon_map(dragon_dataset(toy_df(5)), prompt = "subject", response = "reply")
  state <- shiny::reactiveValues(dataset = ds, mapped = NULL)
  shiny::testServer(dragonfarm:::mod_mapping_server, args = list(state = state, nav_to = function(p) NULL), {
    session$setInputs(prompt_tpl = "", response_tpl = "", system_tpl = "")
    session$flushReact()
    expect_s3_class(state$mapped, "dragon_dataset")
    expect_match(state$mapped$mapping$prompt, "subject")
    session$setInputs(prompt_tpl = "{body}", response_tpl = "reply")   # typing templates takes over
    session$flushReact()
    expect_match(state$mapped$mapping$prompt, "body")
  })
})

test_that("the train module refuses to launch without inputs", {
  state <- shiny::reactiveValues(dataset = NULL, mapped = NULL, model = NULL, run = NULL)
  shiny::testServer(dragonfarm:::mod_train_server, args = list(state = state, nav_to = function(p) NULL), {
    expect_length(problems(), 3)
    state$dataset <- dragon_dataset(toy_df())
    state$mapped <- dragon_map(state$dataset, "subject", "reply")
    state$model <- list(id = "x/y", trust_remote_code = FALSE)
    expect_length(problems(), 0)
  })
})

test_that("the app object builds", {
  app <- dragon_app(runs_dir = tempfile("runs-"))
  expect_s3_class(app, "shiny.appobj")
})

test_that("the RStudio add-in opens the app", {
  dcf <- read.dcf(system.file("rstudio", "addins.dcf", package = "dragonfarm"))
  expect_equal(unname(dcf[1, "Name"]), "dragonfarm")
  binding <- unname(dcf[1, "Binding"])
  expect_true(is.function(get(binding, envir = asNamespace("dragonfarm"))))
  expect_true(binding %in% getNamespaceExports("dragonfarm"))
})

test_that("the header badge shows the device and whether agents are on", {
  big <- as.character(dragonfarm:::hw_badge(list(device = "cuda", device_name = "RTX", vram_gb = 8,
                                                 tier = list(model = "Qwen/Qwen2.5-7B-Instruct"))))
  expect_match(big, "agents on"); expect_match(big, "GPU RTX")
  small <- as.character(dragonfarm:::hw_badge(list(device = "cpu", tier = list(model = "Qwen/Qwen2.5-0.5B-Instruct"))))
  expect_match(small, "fixed workflows"); expect_match(small, "3B or larger")
  expect_match(as.character(dragonfarm:::hw_badge(NULL)), "not checked")
})
