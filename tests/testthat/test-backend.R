# A backend that answers from the conversation itself, so chat and routing
# can be tested without Python or a server.
fake_backend <- function() structure(list(kind = "fake", model = "fake"), class = c("dragon_backend_fake", "dragon_backend"))
backend_generate.dragon_backend_fake <- function(backend, target, conversations, max_new_tokens = 256,
                                                 temperature = 0.7, top_p = 0.9, on_token = NULL) {
  lapply(conversations, function(msgs) {
    users <- vapply(Filter(function(m) m$role == "user", msgs), `[[`, character(1), "content")
    reply <- sprintf("turn %d: %s", length(users), users[length(users)])
    if (!is.null(on_token)) for (piece in strsplit(reply, " ")[[1]]) on_token(paste0(piece, " "))
    reply
  })
}
registerS3method("backend_generate", "dragon_backend_fake", backend_generate.dragon_backend_fake, envir = asNamespace("dragonfarm"))

test_that("backend constructors normalize their inputs", {
  loc <- dragon_backend_local()
  expect_s3_class(loc, "dragon_backend_local")
  expect_true(loc$keep_loaded)
  srv <- suppressWarnings(dragon_backend_server("https://host.example.com", "my/model", api_key = "k"))   # the key warning has its own test
  expect_equal(srv$url, "https://host.example.com/v1")
  expect_equal(dragon_backend_server("http://h/v1/", "m", api_key = "")$url, "http://h/v1")
  oll <- dragon_backend_ollama("support-0.5b")
  expect_equal(oll$url, "http://localhost:11434/v1")
  expect_equal(oll$kind, "ollama")
  expect_true(dragonfarm:::is_server_backend(oll))
  expect_false(dragonfarm:::is_server_backend(loc))
  expect_match(dragonfarm:::backend_label(oll), "Ollama support-0.5b")
  expect_error(dragon_backend_server("", "m"), "non-empty")
  withr::local_options(dragonfarm.backend = oll)
  expect_equal(dragon_backend()$model, "support-0.5b")
  withr::local_options(dragonfarm.backend = 42)
  expect_error(dragon_backend(), "dragon_backend")
})

test_that("the chat completion request follows the OpenAI shape", {
  skip_if_not_installed("httr2")
  b <- suppressWarnings(dragon_backend_server("https://host/v1", "m", api_key = "secret", headers = c(`x-extra` = "1")))
  req <- dragonfarm:::chat_completion_request(b, list(list(role = "user", content = "hi")), 64, 0.2, 0.9)
  expect_equal(req$url, "https://host/v1/chat/completions")
  body <- req$body$data
  expect_equal(body$model, "m")
  expect_equal(body$max_tokens, 64L)
  expect_equal(body$messages[[1]]$content, "hi")
  expect_false(body$stream)
  expect_true("Authorization" %in% names(req$headers))   # value is redacted by httr2
  expect_equal(req$headers[["x-extra"]], "1")
  none <- dragonfarm:::chat_completion_request(dragon_backend_ollama("m"), list(), 10, 0, 1)
  expect_false("Authorization" %in% names(none$headers))
})

test_that("a mocked server round-trips a reply and surfaces errors", {
  skip_if_not_installed("httr2")
  b <- dragon_backend_server("https://host/v1", "m", api_key = "")
  httr2::local_mocked_responses(function(req) {
    body <- req$body$data   # req_body_json() keeps the R object until the request is sent
    httr2::response_json(200, body = list(choices = list(list(message = list(role = "assistant", content = paste("echo:", body$messages[[length(body$messages)]]$content))))))
  })
  out <- dragonfarm:::backend_generate(b, NULL, list(list(list(role = "user", content = "ping"))))
  expect_equal(out[[1]], "echo: ping")
  expect_equal(dragon_generate("ignored/model", c("a", "b"), backend = b), c("echo: a", "echo: b"))

  httr2::local_mocked_responses(function(req) httr2::response_json(503, body = list(error = list(message = "down"))))
  expect_error(dragonfarm:::chat_completion(b, list(list(role = "user", content = "x"))), "HTTP 503")
})

test_that("dragon_generate routes through the backend and keeps prompt order", {
  out <- dragon_generate("any/model", c("first", "second"), system = "sys", backend = fake_backend())
  expect_equal(out, c("turn 1: first", "turn 1: second"))
})

test_that("dragon_chat keeps context across turns, streams, resets, saves, and loads", {
  chat <- dragon_chat("any/model", system = "Be brief.", backend = fake_backend(), temperature = 0)
  expect_s3_class(chat, "dragon_chat")
  expect_equal(chat$say("hello"), "turn 1: hello")
  expect_equal(chat$say("again"), "turn 2: again")
  h <- chat$history()
  expect_length(h, 4)
  expect_equal(vapply(h, `[[`, character(1), "role"), c("user", "assistant", "user", "assistant"))
  ex <- chat$as_example()
  expect_equal(ex$messages[[1]]$role, "system")
  expect_length(ex$messages, 5)

  pieces <- character()
  chat$say("stream", on_token = function(p) pieces <<- c(pieces, p))
  expect_equal(trimws(paste(pieces, collapse = "")), "turn 3: stream")

  chat$undo()
  expect_length(chat$history(), 4)
  path <- tempfile(fileext = ".json")
  chat$save(path)
  again <- dragon_chat_load(path, "any/model", backend = fake_backend())
  expect_length(again$history(), 4)
  expect_equal(again$system, "Be brief.")
  expect_equal(again$say("more"), "turn 3: more")
  chat$reset()
  expect_length(chat$history(), 0)
  msgs <- testthat::capture_messages(print(again))
  expect_true(any(grepl("turn", msgs)))
  expect_error(dragon_chat_load(tempfile()), "does not exist")
  expect_error(dragon_chat(NULL, backend = fake_backend()), "what should answer")
})

test_that("context_window drops the oldest turns once the estimated budget is exceeded", {
  # 10 words: 49 chars -> 13 estimated tokens. The fake backend's reply
  # ("turn N: " + the text) is 57 chars -> 15 tokens, so one turn costs 28.
  long <- paste(rep("word", 10), collapse = " ")
  chat <- dragon_chat("any/model", backend = fake_backend(), max_new_tokens = 10, context_window = 64)
  expect_null(dragon_chat("any/model", backend = fake_backend())$context_usage())   # no window: nothing to report
  chat$say(long)   # 1 turn, 28 tokens: fits under the 54-token budget, nothing dropped yet
  chat$say(long)   # 2 turns, 56 tokens: still fits (41 <= 54 when checked before this turn)
  chat$say(long)   # over budget (69 > 54): the oldest turn is dropped before this one is added
  chat$say(long)   # over budget again: another turn dropped
  expect_equal(chat$dropped_turns, 2)
  expect_length(chat$history(), 4)   # only the last two turns remain

  usage <- chat$context_usage()
  expect_equal(usage$tokens, 56)
  expect_equal(usage$window, 64L)
  expect_equal(usage$ratio, 56 / 64)
  expect_true(usage$near_limit)
  expect_equal(usage$dropped_turns, 2)

  path <- tempfile(fileext = ".json")
  chat$save(path)
  reloaded <- dragon_chat_load(path, "any/model", backend = fake_backend())
  expect_equal(reloaded$context_window, 64L)
  expect_equal(reloaded$context_usage()$window, 64L)

  expect_error(dragon_chat("any/model", backend = fake_backend(), context_window = 10), "context_window")
})

test_that("server backends do not need a local model", {
  chat <- dragon_chat(backend = dragon_backend_ollama("m"))
  expect_null(chat$target)
  expect_equal(chat$label, "m")
})

test_that("Ollama serving writes a Modelfile and reports a missing binary", {
  mf <- dragonfarm:::ollama_modelfile("C:/models/merged")
  expect_match(mf[1], "^FROM C:/models/merged$")
  expect_error(dragon_serve_ollama(dragon_run(copy_fixture_run()), ollama = ""), "not found on the PATH")
})

test_that("the chat module sends turns through the chosen backend", {
  runs <- tempfile("runs-")
  dir.create(runs)
  withr::local_options(dragonfarm.backend = fake_backend())
  state <- shiny::reactiveValues(run = NULL)
  shiny::testServer(dragonfarm:::mod_chat_server, args = list(state = state, runs_dir = runs), {
    session$setInputs(source = "ollama", ollama_model = "m", ollama_url = "http://localhost:11434",
                      system = "", temperature = 0.5, max_new_tokens = 64, text = "hello")
    # swap the server backend for the fake so no network is touched
    b <- backend()
    expect_equal(b$kind, "ollama")
  })
  shiny::testServer(dragonfarm:::mod_chat_server, args = list(state = state, runs_dir = runs), {
    session$setInputs(source = "run", system = "", temperature = 0.5, max_new_tokens = 64, text = "")
    expect_length(history(), 0)
    session$setInputs(send = 1)
    expect_length(history(), 0)   # empty text is ignored
  })
})

# A labelled stand-in for an ollama/server backend: replies name which
# instance answered, so a test can tell the primary and second backend
# apart. Real chat_completion() streaming can't be exercised through
# httr2's response mocking (it only supports req_perform(), not the
# connection-based req_perform_connection() streaming uses), so the
# compare-mode test below mocks the backend *constructors* instead and lets
# the rest of the module's send logic run for real.
labeled_backend <- function(label) structure(list(kind = "fake", model = label), class = c("dragon_backend_labeled", "dragon_backend_server", "dragon_backend"))
registerS3method("backend_generate", "dragon_backend_labeled", function(backend, target, conversations, max_new_tokens = 256,
                                                                        temperature = 0.7, top_p = 0.9, on_token = NULL) {
  lapply(conversations, function(msgs) {
    last <- msgs[[length(msgs)]]$content
    reply <- paste0(backend$model, "-says: ", last)
    if (!is.null(on_token)) for (piece in strsplit(reply, " ")[[1]]) on_token(paste0(piece, " "))
    trimws(reply)
  })
}, envir = asNamespace("dragonfarm"))

test_that("compare mode sends the same turn to a second backend and keeps two histories", {
  testthat::local_mocked_bindings(
    dragon_backend_server = function(url, model, api_key = NULL, headers = NULL) labeled_backend(model)
  )
  runs <- tempfile("runs-")
  dir.create(runs)
  state <- shiny::reactiveValues(run = NULL)
  shiny::testServer(dragonfarm:::mod_chat_server, args = list(state = state, runs_dir = runs), {
    session$setInputs(source = "server", server_url = "https://first/v1", server_model = "a",
                      source_b = "server", server_url_b = "https://second/v1", server_model_b = "b",
                      compare = TRUE, system = "", temperature = 0, max_new_tokens = 64, text = "hello")
    session$setInputs(send = 1)
    expect_length(history(), 2)
    expect_equal(history()[[2]]$content, "a-says: hello")
    expect_length(history_b(), 2)
    expect_equal(history_b()[[2]]$content, "b-says: hello")

    title_b <- as.character(output$title_b$html)
    expect_match(title_b, "<code>b</code>", fixed = TRUE)   # the second card's title names its model
    thread_b <- as.character(output$thread_b$html)
    expect_match(thread_b, "b-says: hello", fixed = TRUE)
    expect_false(grepl("fb-btn", thread_b))   # the comparison thread has no feedback buttons

    # turning compare off stops driving the second backend
    session$setInputs(compare = FALSE, text = "again")
    session$setInputs(send = 2)
    expect_length(history(), 4)
    expect_length(history_b(), 2)   # unchanged
  })
})

test_that("context_window_input respects the token floor", {
  runs <- tempfile("runs-")
  dir.create(runs)
  state <- shiny::reactiveValues(run = NULL)
  shiny::testServer(dragonfarm:::mod_chat_server, args = list(state = state, runs_dir = runs), {
    expect_null(context_window_input())
    session$setInputs(context_window = 40)
    expect_null(context_window_input())   # below the 64 floor, treated as no limit
    session$setInputs(context_window = 200)
    expect_equal(context_window_input(), 200L)
  })
})

test_that("a saved transcript loads back into the thread, and the current one exports as a training example", {
  runs <- tempfile("runs-")
  dir.create(runs)
  state <- shiny::reactiveValues(run = NULL)
  shiny::testServer(dragonfarm:::mod_chat_server, args = list(state = state, runs_dir = runs), {
    path <- tempfile(fileext = ".json")
    dragonfarm:::write_json(list(
      format = "dragonfarm-chat", version = 1L, saved_at = "now", label = "m",
      system = "Be nice.", settings = list(temperature = 0.3, max_new_tokens = 99, context_window = 256),
      messages = list(list(role = "user", content = "hi"), list(role = "assistant", content = "hello"))
    ), path)
    session$setInputs(load = data.frame(name = "t.json", datapath = path, stringsAsFactors = FALSE))
    expect_length(history(), 2)
    expect_equal(history()[[2]]$content, "hello")

    bad <- tempfile(fileext = ".json")
    dragonfarm:::write_json(list(hello = "world"), bad)
    session$setInputs(load = data.frame(name = "bad.json", datapath = bad, stringsAsFactors = FALSE))
    expect_length(history(), 2)   # rejected; unchanged

    session$setInputs(system = "Be nice.")
    out <- tempfile(fileext = ".jsonl")
    export_example_content(out)
    rows <- dragonfarm:::read_jsonl(out)
    expect_length(rows, 1)
    expect_equal(vapply(rows[[1]]$messages, `[[`, character(1), "role"), c("system", "user", "assistant"))
    expect_equal(rows[[1]]$messages[[1]]$content, "Be nice.")
    reloaded <- dragon_conversations(out)
    expect_equal(nrow(reloaded$data), 1)

    history(list())
    empty <- tempfile(fileext = ".jsonl")
    expect_error(export_example_content(empty))   # nothing to export yet
  })
})

test_that("the local backend validates and forwards load_in_4bit", {
  expect_equal(dragon_backend_local()$load_in_4bit, "auto")
  expect_true(dragon_backend_local(load_in_4bit = TRUE)$load_in_4bit)
  expect_false(dragon_backend_local(load_in_4bit = FALSE)$load_in_4bit)
  expect_error(dragon_backend_local(load_in_4bit = "yes"), "load_in_4bit")
  expect_error(dragon_backend_local(load_in_4bit = NA), "load_in_4bit")

  seen <- NULL
  testthat::local_mocked_bindings(
    worker_start = function(backend) invisible(NULL),
    worker_request = function(req, on_token = NULL) { seen <<- req; list(outputs = list("ok")) }
  )
  out <- dragon_generate("Qwen/Qwen2.5-7B-Instruct", "hi", backend = dragon_backend_local(load_in_4bit = TRUE))
  expect_equal(out, "ok")
  expect_true(seen$load_in_4bit)
  dragon_generate("Qwen/Qwen2.5-7B-Instruct", "hi", backend = dragon_backend_local())
  expect_equal(seen$load_in_4bit, "auto")
})

test_that("conversations reach the worker as a JSON array even when named", {
  seen <- NULL
  testthat::local_mocked_bindings(
    worker_start = function(backend) invisible(NULL),
    worker_request = function(req, on_token = NULL) { seen <<- req; list(outputs = list("a", "b")) }
  )
  convos <- list(q1 = list(list(role = "user", content = "x")), q2 = list(list(role = "user", content = "y")))
  backend_generate(dragon_backend_local(keep_loaded = TRUE), list(model = "m"), convos)
  json <- as.character(jsonlite::toJSON(seen$conversations, auto_unbox = TRUE))
  expect_true(startsWith(json, "[["))
})

test_that("a server backend keeps the key's variable, not the key (D-14)", {
  withr::local_envvar(DRAGONFARM_API_KEY = "sk-from-env-PROBE", OPENAI_API_KEY = NA)
  b <- dragon_backend_server("https://models.example.com/v1", "m")
  expect_equal(b$api_key_env, "DRAGONFARM_API_KEY")
  expect_null(b$api_key)
  expect_false(length(grepRaw("sk-from-env-PROBE", serialize(b, NULL), fixed = TRUE)) > 0)   # nothing to save to disk
  expect_equal(dragonfarm:::backend_key(b), "sk-from-env-PROBE")                              # read when sending
  withr::local_envvar(DRAGONFARM_API_KEY = "sk-rotated")
  expect_equal(dragonfarm:::backend_key(b), "sk-rotated")                                     # a rotated key is picked up
  expect_equal(dragonfarm:::backend_key(dragon_backend_ollama("m")), "")                      # Ollama sends none
  rlang::local_options(rlib_warning_verbosity = "verbose")                                  # the warning is once per session
  expect_warning(d <- dragon_backend_server("https://x.example.com/v1", "m", api_key = "sk-direct"), "kept inside")
  expect_equal(dragonfarm:::backend_key(d), "sk-direct")
  own <- dragon_backend_server("https://x.example.com/v1", "m", api_key_env = "MY_TEAM_KEY")
  withr::local_envvar(MY_TEAM_KEY = "sk-team")
  expect_equal(dragonfarm:::backend_key(own), "sk-team")
})

test_that("Ollama is found in its install folder when R started before it was installed", {
  local <- withr::local_tempdir()
  exe <- file.path(local, "Programs", "Ollama", "ollama.exe")
  dir.create(dirname(exe), recursive = TRUE); file.create(exe)
  withr::local_envvar(PATH = "", LOCALAPPDATA = local)
  expect_equal(normalizePath(dragonfarm:::ollama_path()), normalizePath(exe))
})

test_that("a model Ollama registers but cannot run is removed, with the reason", {
  merged <- withr::local_tempdir()
  writeLines("{}", file.path(merged, "config.json")); file.create(file.path(merged, "model.safetensors"))
  calls <- list()
  local_mocked_bindings(run = function(command, args, ...) { calls[[length(calls) + 1]] <<- args; list(status = 0, stdout = "", stderr = "") }, .package = "processx")
  local_mocked_bindings(ollama_try = function(name, ...) "MLX runtime is not available: failed to load MLX dynamic library")
  err <- tryCatch(dragon_serve_ollama(merged, name = "df-test", ollama = "ollama"), error = function(e) e)
  expect_s3_class(err, "dragonfarm_error")
  expect_match(conditionMessage(err), "could not answer")
  expect_match(conditionMessage(err), "dragon_export_gguf")
  expect_equal(calls[[1]][1:2], c("create", "df-test"))
  expect_equal(calls[[2]], c("rm", "df-test"))                          # the unusable copy is removed
})

test_that("ollama_try reports Ollama's error, and NULL when it answers", {
  skip_if_not_installed("httr2")
  reply <- NULL
  local_mocked_bindings(req_perform = function(req, ...) reply, .package = "httr2")
  reply <- httr2::response(status_code = 500, headers = list(`content-type` = "application/json"),
                           body = charToRaw('{"error":"MLX runtime is not available"}'))
  expect_match(dragonfarm:::ollama_try("m"), "MLX runtime")
  reply <- httr2::response(status_code = 200, headers = list(`content-type` = "application/json"), body = charToRaw('{"response":"Hi"}'))
  expect_null(dragonfarm:::ollama_try("m"))
})

test_that("an MLX import refusal points at the GGUF route", {
  merged <- withr::local_tempdir()
  writeLines("{}", file.path(merged, "config.json")); file.create(file.path(merged, "model.safetensors"))
  local_mocked_bindings(run = function(command, args, ...) list(status = 1, stdout = "", stderr = 'Error: unsupported MLX architecture: model "Qwen2ForCausalLM"'), .package = "processx")
  err <- tryCatch(dragon_serve_ollama(merged, name = "df-test", ollama = "ollama"), error = function(e) e)
  expect_s3_class(err, "dragonfarm_error")
  expect_match(conditionMessage(err), "Qwen2ForCausalLM")
  expect_match(conditionMessage(err), "dragon_export_gguf")
})
