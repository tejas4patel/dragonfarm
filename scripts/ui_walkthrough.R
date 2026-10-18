# A UI-only walkthrough of the app, end to end, in headless Chrome: what a
# person does with the mouse and keyboard, with no R code typed. Table route:
# load the example tickets, map the columns, pick the smallest model, train,
# watch the run finish, and ask the trained model a question. Needs chromote
# and callr; trains a 135M model for 12 steps (a few minutes on a GPU).
#   Rscript scripts/ui_walkthrough.R [out dir]
args <- commandArgs(trailingOnly = TRUE)
S <- if (length(args)) args[[1]] else tempfile("walk-")
dir.create(S, showWarnings = FALSE, recursive = TRUE)
runs <- file.path(S, "runs")
port <- 3941
pkg <- normalizePath(".")
say <- function(...) { cat(format(Sys.time(), "%H:%M:%S"), ..., "\n"); cat(format(Sys.time(), "%H:%M:%S"), ..., "\n", file = file.path(S, "walk.txt"), append = TRUE) }
srv <- callr::r_bg(function(port, runs, pkg) {
  devtools::load_all(pkg, quiet = TRUE)
  shiny::runApp(dragon_app(runs_dir = runs, route = "table"), port = port, host = "127.0.0.1", launch.browser = FALSE)
}, args = list(port = port, runs = runs, pkg = pkg), stdout = file.path(S, "app.out"), stderr = "2>&1")
for (i in 1:90) { ok <- tryCatch({ readLines(sprintf("http://127.0.0.1:%d", port), warn = FALSE); TRUE }, error = function(e) FALSE, warning = function(w) FALSE); if (ok) break; Sys.sleep(1) }
stopifnot(ok)
b <- chromote::ChromoteSession$new(width = 1280, height = 900)
b$Page$navigate(sprintf("http://127.0.0.1:%d", port)); Sys.sleep(6)
js <- function(code) b$Runtime$evaluate(code, returnByValue = TRUE)$result$value
tab <- function(v) js(sprintf("bootstrap.Tab.getOrCreateInstance(document.querySelector('.navbar .nav-link[data-value=\"%s\"]')).show()", v))
click <- function(id) js(sprintf("document.getElementById('%s').click()", id))
type <- function(id, text) js(sprintf("$('#%s').val(%s).trigger('input').trigger('change')", id, jsonlite::toJSON(text, auto_unbox = TRUE)))
text_of <- function(sel) js(sprintf("(document.querySelector('%s') || {}).innerText || ''", sel))
wait_for <- function(what, cond, secs = 60) {
  for (i in seq_len(secs)) { if (isTRUE(cond())) { say("ok:", what); return(TRUE) }; Sys.sleep(1) }
  say("TIMED OUT:", what); FALSE
}
shot <- function(name) writeBin(jsonlite::base64_dec(b$Page$captureScreenshot(format = "png")$data), file.path(S, paste0(name, ".png")))
steps <- list()
step <- function(name, ok) { steps[[name]] <<- isTRUE(ok); shot(name) }

say("1 Data: load the example tickets")
tab("data"); Sys.sleep(1); click("data-example")
step("1-data", wait_for("rows shown", function() grepl("Rows", text_of("#data-summary")), 30))

say("2 Map: prompt and response from the columns")
tab("map"); Sys.sleep(2)
# One-line boxes: a typed \n is a line break.
type("map-prompt_tpl", "{subject}\\n\\n{body}"); type("map-response_tpl", "{reply}"); Sys.sleep(2)
step("2-map", wait_for("preview filled", function() grepl("Lumen|Sentry|Ember|thermostat", text_of("#map-preview"), ignore.case = TRUE), 30))

say("3 Model: the smallest preset")
tab("model"); Sys.sleep(2)
js("$('input[name=\"model-preset\"][value=\"HuggingFaceTB/SmolLM2-135M-Instruct\"]').prop('checked', true).trigger('change')")
Sys.sleep(1); step("3-model", TRUE)

say("4 Train: one short run")
tab("train"); Sys.sleep(2)
type("train-max_steps", "12"); Sys.sleep(1)
step("4-checklist", wait_for("checklist ready", function() grepl("training rows", text_of("#train-checklist")), 20))
click("train-start")
started <- wait_for("run started (Monitor shown)", function() grepl("Monitor", text_of(".navbar .nav-link.active")), 120)

say("5 Monitor: until the run succeeds")
done <- wait_for("run succeeded", function() grepl("SUCCEEDED", toupper(text_of("#monitor-facts"))), 900)
step("5-monitor", started && done)

say("6 Try it: ask the trained model")
tab("tryit"); Sys.sleep(3)
type("tryit-prompt", "Lumen bulb pack arrived damaged\n\nTwo of the four bulbs were cracked."); Sys.sleep(1)   # a textarea: real line breaks
click("tryit-go")
step("6-tryit", wait_for("a reply", function() { t <- text_of("#tryit-tuned"); nzchar(t) && !grepl("Nothing generated yet", t) }, 300))
say("reply:", substr(text_of("#tryit-tuned"), 1, 160))

say("RESULT:", sum(unlist(steps)), "of", length(steps), "steps passed:", paste(names(steps)[!unlist(steps)], collapse = ", "))
b$close(); srv$kill()
