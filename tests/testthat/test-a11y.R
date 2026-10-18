# Accessibility basics that can be checked without a browser. The full
# WCAG 2.1 A/AA audit (axe-core in headless Chrome) is scripts/a11y_audit.R.

app_ui_html <- function(route = "documents") {
  app <- dragon_app(runs_dir = withr::local_tempdir(.local_envir = parent.frame()), route = route)
  ui <- environment(app$httpHandler)$ui
  list(ui = ui, html = htmltools::renderTags(ui)$html)
}

unlabelled_controls <- function(html) {
  tags <- regmatches(html, gregexpr("<(input|textarea|select)\\b[^>]*>", html, perl = TRUE))[[1]]
  typ <- sub('.*\\btype="([^"]+)".*', "\\1", tags, perl = TRUE)
  typ[!grepl('\\btype="', tags, perl = TRUE)] <- "text"
  keep <- !typ %in% c("hidden", "checkbox", "radio", "submit", "button", "file") & grepl('\\bid="', tags, perl = TRUE)
  ids <- sub('.*\\bid="([^"]+)".*', "\\1", tags[keep], perl = TRUE)
  has_aria <- grepl("aria-label(ledby)?=", tags[keep])
  labelled <- vapply(ids, function(id) {
    m <- regmatches(html, regexpr(sprintf('(?s)<label[^>]*for="%s"[^>]*>.*?</label>', id), html, perl = TRUE))
    length(m) == 1 && nzchar(trimws(gsub("<[^>]+>", "", m)))
  }, TRUE)
  unname(ids[!labelled & !has_aria])
}

test_that("the app declares its language", {
  expect_equal(attr(app_ui_html()$ui, "lang"), "en")
})

test_that("every text box and drop-down in the app has a label", {
  for (route in c("documents", "table")) expect_equal(unlabelled_controls(app_ui_html(route)$html), character(), info = route)
})

test_that("the label check catches a missing label", {
  html <- as.character(htmltools::tagList(shiny::textInput("a", NULL), shiny::textInput("b", "Name")))
  expect_equal(unlabelled_controls(html), "a")
})

test_that("scrolling text boxes can be reached with the keyboard and are named", {
  html <- as.character(dragonfarm:::mod_monitor_ui("monitor"))
  for (id in c("monitor-log", "monitor-code", "monitor-activity_detail")) {
    tag <- regmatches(html, regexpr(sprintf('<pre[^>]*id="%s"[^>]*>', id), html))
    expect_match(tag, 'tabindex="0"', info = id)
    expect_match(tag, 'aria-label="[^"]+"', info = id)
  }
})

test_that("small hint text is coloured, not faded, so it keeps AA contrast", {
  # Faded text is invisible to axe's contrast check when another element
  # overlaps it; the trace note under an answer measured 4.29:1 at 0.65.
  css <- readLines(system.file("app", "www", "dragonfarm.css", package = "dragonfarm"), warn = FALSE)
  rule <- function(sel) css[startsWith(css, paste0(sel, " {"))]
  expect_match(rule(".trace-note"), "color: var(--df-muted)", fixed = TRUE)
  expect_false(grepl("opacity", rule(".trace-note")))
  expect_match(rule(".form-control::placeholder"), "opacity: 1;", fixed = TRUE)
})
