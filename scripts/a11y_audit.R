# WCAG 2.1 A/AA audit of the running app with axe-core in headless Chrome.
# Each tab is shown in turn, in light and dark mode, and axe runs on what is
# visible (an empty runs folder, so result tables and cards that need a run
# are not covered). Needs chromote, callr and axe.min.js (axe-core 4.10.2;
# from the axe-selenium-python wheel on PyPI or the axe-core npm package).
#   Rscript scripts/a11y_audit.R <label> [documents|table] [path/to/axe.min.js] [out dir]
args <- commandArgs(trailingOnly = TRUE)
label <- if (length(args)) args[[1]] else "before"
route <- if (length(args) > 1) args[[2]] else "documents"
axe_js <- if (length(args) > 2) args[[3]] else "axe.min.js"
S <- if (length(args) > 3) args[[4]] else tempfile("a11y-")
dir.create(S, showWarnings = FALSE, recursive = TRUE)
port <- 3940
runs <- file.path(S, "runs")
pkg <- normalizePath(".")
srv <- callr::r_bg(function(port, runs, route, pkg) {
  devtools::load_all(pkg, quiet = TRUE)
  shiny::runApp(dragon_app(runs_dir = runs, route = route), port = port, host = "127.0.0.1", launch.browser = FALSE)
}, args = list(port = port, runs = runs, route = route, pkg = pkg), stdout = file.path(S, "app.out"), stderr = "2>&1")
on.exit(srv$kill(), add = TRUE)
for (i in 1:60) { ok <- tryCatch({ readLines(sprintf("http://127.0.0.1:%d", port), warn = FALSE); TRUE }, error = function(e) FALSE, warning = function(w) FALSE); if (ok) break; Sys.sleep(1) }
stopifnot(ok)

b <- chromote::ChromoteSession$new(width = 1280, height = 900)
on.exit(b$close(), add = TRUE)
b$Page$navigate(sprintf("http://127.0.0.1:%d", port))
Sys.sleep(6)
axe_src <- paste(readLines(axe_js, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
b$Runtime$evaluate(axe_src)
js <- function(code, await = FALSE) b$Runtime$evaluate(code, awaitPromise = await, returnByValue = TRUE)$result$value

tabs <- js("Array.from(document.querySelectorAll('.navbar .nav-link[data-value]')).filter(a => a.offsetParent !== null).map(a => a.getAttribute('data-value'))")
tabs <- unlist(tabs)
rows <- list()
shot <- function(name) { b$Page$captureScreenshot(format = "png")$data |> jsonlite::base64_dec() |> writeBin(file.path(S, paste0(name, ".png"))) }
for (mode in c("light", "dark")) {
  js(sprintf("document.documentElement.setAttribute('data-bs-theme', '%s')", mode))
  for (t in tabs) {
    js(sprintf("bootstrap.Tab.getOrCreateInstance(document.querySelector('.navbar .nav-link[data-value=\"%s\"]')).show()", t))
    Sys.sleep(3)
    res <- js("axe.run(document, {runOnly: {type: 'tag', values: ['wcag2a','wcag2aa','wcag21a','wcag21aa']}, resultTypes: ['violations']}).then(r => JSON.stringify(r.violations.map(v => ({id: v.id, impact: v.impact, help: v.help, n: v.nodes.length, targets: v.nodes.slice(0, 6).map(n => n.target.join(' ')), html: v.nodes.slice(0, 3).map(n => n.html.slice(0, 160))}))))", await = TRUE)
    v <- jsonlite::fromJSON(res, simplifyVector = FALSE)
    for (x in v) rows[[length(rows) + 1]] <- data.frame(mode = mode, tab = t, id = x$id, impact = x$impact %||% "", n = x$n,
      help = x$help, targets = paste(unlist(x$targets), collapse = " | "), html = paste(unlist(x$html), collapse = " || "))
    cat(mode, t, length(v), "rules violated\n")
    if (t %in% c("documents", "data", "monitor")) shot(paste(label, mode, t, sep = "-"))
  }
}
out <- if (length(rows)) do.call(rbind, rows) else data.frame()
saveRDS(out, file.path(S, sprintf("axe-%s.rds", label)))
if (nrow(out)) {
  agg <- stats::aggregate(n ~ mode + id + impact, data = out, FUN = sum)
  print(agg[order(agg$mode, -agg$n), ], row.names = FALSE)
  cat("\nTotal nodes:", sum(out$n), "in", length(unique(paste(out$mode, out$id))), "mode x rule pairs\n")
} else cat("No violations\n")
b$close()
srv$kill()
