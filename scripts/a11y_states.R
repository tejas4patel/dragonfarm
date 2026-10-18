# WCAG 2.1 A/AA audit (axe-core) of the states that only appear after an
# action, which scripts/a11y_audit.R cannot reach: a generated reply with
# the base model's beside it, a judge's verdict, a chat with feedback
# buttons, an answer with its sources, and the review of written questions.
# Each state is audited in light and dark mode on the tab that shows it.
# Uses the GPU (small models only). Needs chromote, callr, axe.min.js and a
# finished run (for example one made by scripts/ui_walkthrough.R).
#   Rscript scripts/a11y_states.R <run dir> [path/to/axe.min.js] [out dir]
args <- commandArgs(trailingOnly = TRUE)
run_dir <- args[[1]]
axe_js <- if (length(args) > 1) args[[2]] else "axe.min.js"
S <- if (length(args) > 2) args[[3]] else tempfile("a11y-states-")
dir.create(S, showWarnings = FALSE, recursive = TRUE)
pkg <- normalizePath(".")
small <- "Qwen/Qwen2.5-0.5B-Instruct"
axe_src <- paste(readLines(axe_js, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
say <- function(...) { line <- paste(format(Sys.time(), "%H:%M:%S"), ...); cat(line, "\n"); cat(line, "\n", file = file.path(S, "states.txt"), append = TRUE) }
rows <- list()

start_app <- function(route, port, runs) {
  srv <- callr::r_bg(function(port, runs, route, pkg) {
    devtools::load_all(pkg, quiet = TRUE)
    shiny::runApp(dragon_app(runs_dir = runs, route = route), port = port, host = "127.0.0.1", launch.browser = FALSE)
  }, args = list(port = port, runs = runs, route = route, pkg = pkg), stdout = file.path(S, paste0("app-", route, ".out")), stderr = "2>&1")
  for (i in 1:90) { ok <- tryCatch({ readLines(sprintf("http://127.0.0.1:%d", port), warn = FALSE); TRUE }, error = function(e) FALSE, warning = function(w) FALSE); if (ok) break; Sys.sleep(1) }
  stopifnot(ok)
  b <- chromote::ChromoteSession$new(width = 1280, height = 900)
  b$Page$navigate(sprintf("http://127.0.0.1:%d", port)); Sys.sleep(6)
  b$Runtime$evaluate(axe_src)
  b$Runtime$evaluate(paste(
    "function dfRgb(c) { var m = c.match(/[\\d.]+/g).map(Number); return {r: m[0], g: m[1], b: m[2], a: m.length > 3 ? m[3] : 1}; }",
    "function dfLum(c) { return [c.r, c.g, c.b].map(function(v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); })",
    "  .reduce(function(s, v, i) { return s + v * [0.2126, 0.7152, 0.0722][i]; }, 0); }",
    "function dfContrast(el) { var fg = dfRgb(getComputedStyle(el).color), op = 1, bg = null, e = el;",
    "  for (; e; e = e.parentElement) { var cs = getComputedStyle(e); op *= Number(cs.opacity);",
    "    if (!bg && cs.backgroundImage !== 'none' && cs.backgroundImage.indexOf('gradient') >= 0) return 'gradient background: check its stops';",
    "    var c = dfRgb(cs.backgroundColor); if (!bg && c.a === 1) bg = c; }",
    "  bg = bg || {r: 255, g: 255, b: 255, a: 1}; var a = fg.a * op;",
    "  var f = {r: fg.r * a + bg.r * (1 - a), g: fg.g * a + bg.g * (1 - a), b: fg.b * a + bg.b * (1 - a)};",
    "  var l1 = dfLum(f), l2 = dfLum(bg); return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05); }"))
  list(srv = srv, b = b)
}

# `at` is the element that shows the state. Contrast that axe cannot judge
# ("incomplete") is measured directly with dfContrast() and logged.
audit <- function(app, state, at) {
  b <- app$b
  js <- function(code, await = FALSE) b$Runtime$evaluate(code, awaitPromise = await, returnByValue = TRUE)$result$value
  # Let Shiny finish redrawing (a fading old output measures as low contrast).
  # Some output polls all the time, so in practice this waits the full 30 s.
  for (i in 1:30) { if (isTRUE(js("document.querySelectorAll('.recalculating').length") == 0)) break; Sys.sleep(1) }
  for (mode in c("light", "dark")) {
    js(sprintf("document.documentElement.setAttribute('data-bs-theme', '%s')", mode)); Sys.sleep(1)
    inc <- js(sprintf("axe.run(document.querySelector('%s'), {runOnly: {type: 'rule', values: ['color-contrast']}}).then(r => JSON.stringify(r.incomplete.flatMap(v => v.nodes.map(n => ({target: n.target.join(' '), why: (n.any[0] || {}).message, html: n.html.slice(0, 160)})))))", at), await = TRUE)
    inc <- jsonlite::fromJSON(inc, simplifyVector = FALSE)
    for (x in inc) say("  incomplete:", x$target, "-", x$why, "-", x$html, "- measured:", js(sprintf("dfContrast(document.querySelector(%s))", jsonlite::toJSON(x$target, auto_unbox = TRUE))))
    inc <- length(inc)
    res <- js("axe.run(document, {runOnly: {type: 'tag', values: ['wcag2a','wcag2aa','wcag21a','wcag21aa']}, resultTypes: ['violations']}).then(r => JSON.stringify(r.violations.map(v => ({id: v.id, impact: v.impact, help: v.help, n: v.nodes.length, targets: v.nodes.slice(0, 6).map(n => n.target.join(' ')), html: v.nodes.slice(0, 3).map(n => n.html.slice(0, 160))}))))", await = TRUE)
    v <- jsonlite::fromJSON(res, simplifyVector = FALSE)
    for (x in v) rows[[length(rows) + 1]] <<- data.frame(state = state, mode = mode, id = x$id, impact = x$impact %||% "", n = x$n,
      help = x$help, targets = paste(unlist(x$targets), collapse = " | "), html = paste(unlist(x$html), collapse = " || "))
    say(state, mode, length(v), "rules violated;", inc, "contrast checks incomplete in the state")
    # What was on the page when axe ran (the pages scroll inside a container,
    # so a screenshot shows only the top).
    if (mode == "light") say("  shows:", gsub("[[:space:]]+", " ", substr(js(sprintf("document.querySelector('%s').innerText", at)), 1, 160)))
  }
  js("document.documentElement.setAttribute('data-bs-theme', 'light')")
}

helpers <- function(b) {
  js <- function(code) b$Runtime$evaluate(code, returnByValue = TRUE)$result$value
  list(
    js = js,
    tab = function(v) js(sprintf("bootstrap.Tab.getOrCreateInstance(document.querySelector('.navbar .nav-link[data-value=\"%s\"]')).show()", v)),
    click = function(id) js(sprintf("document.getElementById('%s').click()", id)),
    set = function(id, value) js(sprintf("Shiny.setInputValue('%s', %s, {priority: 'event'})", id, jsonlite::toJSON(value, auto_unbox = TRUE))),
    type = function(id, text) js(sprintf("$('#%s').val(%s).trigger('input').trigger('change')", id, jsonlite::toJSON(text, auto_unbox = TRUE))),
    text_of = function(sel) js(sprintf("(document.querySelector('%s') || {}).innerText || ''", sel)),
    wait_for = function(what, cond, secs = 300) {
      for (i in seq_len(secs)) { if (isTRUE(cond())) { say("ok:", what); return(TRUE) }; Sys.sleep(1) }
      say("TIMED OUT:", what); FALSE
    })
}

# Table route, with the finished run copied in (skip with DRAGONFARM_A11Y_ONLY=documents).
if (!identical(Sys.getenv("DRAGONFARM_A11Y_ONLY"), "documents")) {
runs <- file.path(S, "runs-table"); dir.create(runs, recursive = TRUE, showWarnings = FALSE)
file.copy(run_dir, runs, recursive = TRUE)
app <- start_app("table", 3942, runs); h <- helpers(app$b)
say("Try it: a reply and the base model's")
h$tab("tryit"); Sys.sleep(3)
h$type("tryit-prompt", "My Lumen bulb pack arrived damaged.\n\nTwo bulbs were cracked."); Sys.sleep(1)
h$click("tryit-go")
if (h$wait_for("both replies", function() { t <- h$text_of("#tryit-base"); nzchar(t) && !grepl("Nothing generated yet", t) })) audit(app, "tryit-replies", "#tryit-tuned")
say("Try it: a local judge's verdict")
h$set("tryit-judge_kind", "local"); Sys.sleep(2); h$type("tryit-judge_model", small); h$type("tryit-judge_n", "2"); Sys.sleep(1)
h$click("tryit-judge")
if (h$wait_for("a verdict", function() grepl("win|score|tie|prefer", h$text_of("#tryit-judge_out"), ignore.case = TRUE), 600)) audit(app, "tryit-judge", "#tryit-judge_out")
say("Chat: a conversation with feedback buttons")
h$tab("chat"); Sys.sleep(3)
h$type("chat-text", "Hello, my thermostat keeps dropping off Wi-Fi."); h$click("chat-send")
if (h$wait_for("a chat reply", function() grepl("thermostat|Wi-Fi|network|sorry|help", h$text_of("#chat-panes"), ignore.case = TRUE) &&
                length(h$js("Array.from(document.querySelectorAll('#chat-panes .bubble.assistant')).map(e => e.innerText)")) > 0)) audit(app, "chat-reply", "#chat-panes")
app$b$close(); app$srv$kill()
}

# Documents route: the example policies, an answer, written questions.
runs2 <- file.path(S, "runs-docs"); dir.create(runs2, recursive = TRUE, showWarnings = FALSE)
app <- start_app("documents", 3943, runs2); h <- helpers(app$b)
say("Documents: the example policies, read")
h$tab("documents"); Sys.sleep(2); h$click("documents-example")
h$wait_for("the set is read", function() grepl("chunk", h$text_of("#documents-summary"), ignore.case = TRUE), 300)
say("Documents: an answer with its sources")
h$set("documents-model", small); h$type("documents-question", "How long do I have to return an item?"); Sys.sleep(1)
h$click("documents-ask")
if (h$wait_for("an answer", function() grepl("\\[1\\]|return|days", h$text_of("#documents-answer"), ignore.case = TRUE), 300)) audit(app, "documents-answer", "#documents-answer")
say("Teach: written questions to review")
# The Teach card is part of the documents module; show the tab that holds it.
h$js("var p = document.getElementById('documents-generate').closest('.tab-pane'); bootstrap.Tab.getOrCreateInstance(document.querySelector('.navbar .nav-link[data-value=\"' + p.getAttribute('data-value') + '\"]')).show()")
Sys.sleep(2)
h$set("documents-generator", small); h$type("documents-per_chunk", "1"); Sys.sleep(1)
h$click("documents-generate")
if (h$wait_for("questions to review", function() grepl("Save decisions", h$text_of("#documents-review")), 900)) audit(app, "questions-review", "#documents-review")
app$b$close(); app$srv$kill()

out <- if (length(rows)) do.call(rbind, rows) else data.frame()
saveRDS(out, file.path(S, "axe-states.rds"))
if (nrow(out)) print(stats::aggregate(n ~ state + mode + id + impact, data = out, FUN = sum), row.names = FALSE) else say("No violations in any state")
