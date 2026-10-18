#' Launch the dragonfarm app
#'
#' A Shiny app that walks through the same steps as the R API. The default
#' route starts from documents: drop in files or web pages, ask questions of
#' them with cited sources, then pick a model, train in the background, watch
#' the loss curve, try the result, talk to it with context, and run the whole
#' post-training loop as a pipeline. The table route (a dataset of prompt and
#' response rows, mapped by dragging columns) is one link away, or the start
#' with `route = "table"`. Every run started here is a normal run directory,
#' and the Monitor panel shows the R code that reproduces it.
#'
#' @param runs_dir Directory where runs are stored and listed.
#' @param route Which tabs lead: `"documents"` (Documents, Model, Train,
#'   Monitor, Try it, Chat, Pipeline) or `"table"` (Data, Map, Model, ...).
#'   Either can be switched to from inside the app.
#' @param ... Passed to [shiny::shinyApp()] as `options`.
#' @return A Shiny app object. Printing it runs the app.
#' @export
#' @examples
#' if (interactive()) {
#' dragon_app()
#' dragon_app(route = "table")
#' }
dragon_app <- function(runs_dir = dragon_runs_dir(), route = c("documents", "table"), ...) {
  route <- match.arg(route)
  options(dragonfarm.runs_dir = runs_dir)
  # Imported results zips carry a LoRA adapter, typically tens of megabytes.
  options(shiny.maxRequestSize = 1024 * 1024^2)
  dir.create(runs_dir, recursive = TRUE, showWarnings = FALSE)
  shiny::addResourcePath("dragonfarm", system.file("app", "www", package = "dragonfarm"))
  titles <- route_titles(route)
  # Keys saved in Settings, from the keychain into this session.
  secrets_load()

  ui <- bslib::page_navbar(
    title = shiny::tags$span(class = "df-brand", brand_mark(), shiny::tags$span("dragonfarm")),
    window_title = "dragonfarm",
    id = "nav",
    # Not fillable: otherwise every card shares one screenful of height and
    # panels such as the drag-and-drop slots and the Try it controls get clipped.
    fillable = FALSE,
    theme = bslib::bs_theme(
      version = 5,
      primary = "#E4572E", secondary = "#5A6580", success = "#2E8B57", danger = "#C2410C",
      "navbar-bg" = "#0B1020",
      base_font = bslib::font_collection("Inter", "Segoe UI", "system-ui", "sans-serif"),
      heading_font = bslib::font_collection("Space Grotesk", "Segoe UI", "system-ui", "sans-serif"),
      code_font = bslib::font_collection("JetBrains Mono", "Cascadia Code", "Consolas", "monospace"),
      "border-radius" = "0.65rem", "card-border-radius" = "1.1rem"
    ),
    header = shiny::tags$head(
      shiny::tags$link(rel = "preconnect", href = "https://fonts.googleapis.com"),
      shiny::tags$link(rel = "stylesheet",
                       href = "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Space+Grotesk:wght@500;600;700&family=JetBrains+Mono:wght@400;500&display=swap"),
      shiny::tags$link(rel = "stylesheet", href = paste0("dragonfarm/dragonfarm.css?v=", css_version())),
      shiny::tags$script(src = paste0("dragonfarm/dragonfarm.js?v=", css_version()))
    ),
    # Titles are renumbered client-side for the active route (route_titles()).
    bslib::nav_panel(titles[["documents"]], value = "documents", step_page("documents", mod_documents_ui("documents"))),
    bslib::nav_panel(titles[["data"]], value = "data", step_page("data", mod_data_ui("data"))),
    bslib::nav_panel(titles[["map"]], value = "map", step_page("map", mod_mapping_ui("map"))),
    bslib::nav_panel(titles[["model"]], value = "model", step_page("model", mod_model_ui("model"))),
    bslib::nav_panel(titles[["train"]], value = "train", step_page("train", mod_train_ui("train"))),
    bslib::nav_panel(titles[["monitor"]], value = "monitor", step_page("monitor", mod_monitor_ui("monitor"))),
    bslib::nav_panel(titles[["tryit"]], value = "tryit", step_page("tryit", mod_tryit_ui("tryit"))),
    bslib::nav_panel(titles[["chat"]], value = "chat", step_page("chat", mod_chat_ui("chat"))),
    bslib::nav_panel(titles[["pipeline"]], value = "pipeline", step_page("pipeline", mod_pipeline_ui("pipeline"))),
    bslib::nav_panel(titles[["settings"]], value = "settings", step_page("settings", mod_settings_ui("settings"))),
    bslib::nav_spacer(),
    bslib::nav_item(shiny::uiOutput("hw_badge", inline = TRUE)),
    bslib::nav_item(shiny::tags$span(class = "df-mode", bslib::input_dark_mode(id = "dark_mode", mode = "light")))
  )

  server <- function(input, output, session) {
    state <- shiny::reactiveValues(dataset = NULL, mapped = NULL, model = NULL, run = NULL, hardware = NULL, cloud = NULL,
                                   documents = NULL, route = route)
    nav_to <- function(panel) bslib::nav_select("nav", panel, session = session)

    # The route decides which tabs show and how they are numbered. Hidden
    # tabs still exist, so switching back and forth loses nothing.
    shiny::observeEvent(state$route, {
      r <- state$route
      for (v in c("documents")) if (identical(r, "documents")) bslib::nav_show("nav", v, session = session) else bslib::nav_hide("nav", v, session = session)
      for (v in c("data", "map")) if (identical(r, "table")) bslib::nav_show("nav", v, session = session) else bslib::nav_hide("nav", v, session = session)
      session$sendCustomMessage("df-tab-titles", as.list(route_titles(r)))
    }, ignoreNULL = TRUE)

    mod_documents_server("documents", state, nav_to, runs_dir)
    mod_data_server("data", state, nav_to)
    mod_mapping_server("map", state, nav_to)
    mod_model_server("model", state, nav_to)
    mod_train_server("train", state, nav_to, runs_dir)
    mod_monitor_server("monitor", state, runs_dir)
    mod_tryit_server("tryit", state, runs_dir)
    mod_chat_server("chat", state, runs_dir)
    mod_pipeline_server("pipeline", state, runs_dir)
    mod_settings_server("settings", runs_dir)

    output$hw_badge <- shiny::renderUI(hw_badge(state$hardware))
  }

  shiny::shinyApp(ui, server, options = list(...))
}

# The header badge: the compute device, and whether agents are on (hover
# for the plain sentence from agent_mode()).
hw_badge <- function(hw) {
  if (is.null(hw)) return(shiny::tags$span(class = "hw-badge muted", "hardware not checked"))
  label <- switch(hw$device, cuda = sprintf("GPU %s \u00b7 %.0f GB", hw$device_name, hw$vram_gb),
                  mps = "Apple GPU", "CPU only")
  mode <- agent_mode(hw)
  shiny::tags$span(class = paste("hw-badge", hw$device), title = mode$message, label,
                   shiny::tags$span(class = paste("agent-mode", if (mode$on) "on" else "off"),
                                    if (mode$on) "agents on" else "fixed workflows"))
}

# The logo: the dragonfarm dragon on a navy tile, the same mark as the hex
# sticker and the site's favicon (source in scripts/logo).
brand_mark <- function() {
  shiny::HTML(paste0(
    '<svg class="df-logo" aria-hidden="true" viewBox="0 0 100 100" width="26" height="26">',
    '<rect width="100" height="100" rx="22" fill="#151E3A"/><g transform="translate(9,8) scale(0.84)">',
    '<path d="M42 38 L10 12 L32 44 Z" fill="#FFB547"/><path d="M54 34 L36 6 L46 36 Z" fill="#FFB547"/>',
    '<path d="M30 56 L6 54 L26 70 Z" fill="#FFB547"/><path d="M28 72 L4 74 L28 86 Z" fill="#FFB547"/>',
    '<path d="M26 94 C16 72 18 52 30 40 C38 32 48 28 58 30 L86 40 C93 42 94 49 88 51 L66 56 L70 61 C64 66 56 66 50 64 C46 74 48 84 54 94 Z" fill="#FF6B35"/>',
    '<circle cx="57" cy="40" r="4.2" fill="#0B1020"/><circle cx="86" cy="44" r="1.8" fill="#0B1020"/></g>',
    '</svg>'
  ))
}

# A short heading over each step: what it is for, in one line, in the
# dragon voice of the site. Errors and warnings elsewhere stay plain.
step_intros <- list(
  documents = c("Start here", "Feed the dragon",
                "Drop in files or web pages and ask them anything: it answers from what it read. When you're ready, it writes practice questions for you to mark."),
  data = c("Table route", "Bring your own homework",
           "A CSV, Excel sheet, JSONL file, or data frame of prompts and replies."),
  map = c("Table route", "Show it what each column means",
          "Drag columns into the prompt, response, and system slots, or start from a template."),
  model = c("Choose", "Pick your dragon",
            "Hatchlings (0.5B) learn fixed formats in minutes. An Elder (7B, in 4-bit) gives the best answers on an 8 GB NVIDIA card."),
  train = c("Train", "Off to dragon school",
            "LoRA trains a small adapter on top of the base model. It studies in the background, so the app stays usable."),
  monitor = c("Watch", "Watch it learn",
              "Training loss shows it fitting your examples; held-out loss shows whether it learned the lesson or just memorised the textbook."),
  tryit = c("Compare", "Trained vs. wild",
            "Ask the trained dragon and the original the same question, let a judge decide, then export or publish."),
  chat = c("Talk", "Have a chat with it",
           "Multi-turn chat with context, answers from your documents, and thumbs up or down that become training data."),
  pipeline = c("Automate", "Run the whole training camp",
               "Chain training, judging, and preference tuning into one recipe, and follow each run's family tree."),
  settings = c("Settings", "Keys to the stable",
               "Connect outside services once. Keys stay in this computer's keychain, never in your files.")
)

step_page <- function(key, ui) {
  s <- step_intros[[key]]
  shiny::tagList(
    shiny::div(class = "df-intro",
      shiny::p(class = "df-kicker", s[1]),
      shiny::h2(class = "df-title", s[2]),
      shiny::p(class = "df-sub", s[3])
    ),
    ui
  )
}

# Tab titles for a route: the steps the route shows, numbered in order.
route_titles <- function(route) {
  steps <- if (identical(route, "table")) {
    c(data = "Data", map = "Map", model = "Model", train = "Train", monitor = "Monitor", tryit = "Try it", chat = "Chat", pipeline = "Pipeline")
  } else {
    c(documents = "Documents", model = "Model", train = "Train", monitor = "Monitor", tryit = "Try it", chat = "Chat", pipeline = "Pipeline")
  }
  numbered <- stats::setNames(paste(seq_along(steps), steps), names(steps))
  # Hidden tabs keep a sensible title for when the other route shows them.
  other <- if (identical(route, "table")) c(documents = "Documents") else c(data = "Data", map = "Map")
  c(numbered, other, settings = "Settings")
}

# Cache-busting token for the stylesheet: the file's modification time, so a
# changed file is always refetched by browsers that cached the old one.
css_version <- function() {
  f <- system.file("app", "www", "dragonfarm.css", package = "dragonfarm")
  if (!nzchar(f)) return(utils::packageVersion("dragonfarm"))
  as.integer(file.info(f)$mtime)
}

# Shared helpers for modules ------------------------------------------------

chat_preview_ui <- function(rows) {
  if (!length(rows)) return(NULL)
  shiny::tagList(lapply(seq_along(rows), function(i) {
    msgs <- rows[[i]]$messages
    shiny::div(class = "chat-row",
      shiny::div(class = "chat-row-label", sprintf("Row %d", i)),
      lapply(msgs, function(m) {
        shiny::div(class = paste("bubble", m$role),
          shiny::span(class = "role", m$role),
          shiny::div(class = "content", m$content)
        )
      })
    )
  }))
}

state_pill <- function(state) {
  shiny::span(class = paste("pill", state), state)
}

notify_error <- function(e, session = shiny::getDefaultReactiveDomain()) {
  msg <- conditionMessage(e)
  shiny::showNotification(msg, type = "error", duration = 12, session = session)
}

# Long actions in the app (evaluate, judge, build pairs, merge) run as
# one-step background pipelines so the session stays responsive. A watcher
# polls the record and hands the finished record back to the module.
app_task_start <- function(run, step, runs_dir, name) {
  suppressMessages(dragon_pipeline(run, list(step), runs_dir = runs_dir, name = name, background = TRUE))
}

app_task_watch <- function(handle, on_done, interval = 2000, session = shiny::getDefaultReactiveDomain()) {
  obs <- shiny::observe({
    rec <- tryCatch(dragon_pipeline_status(handle), error = function(e) NULL)
    if (is.null(rec) || rec$status %in% c("queued", "running")) {
      shiny::invalidateLater(interval, session)
      return()
    }
    obs$destroy()
    tryCatch(on_done(rec), error = function(e) notify_error(e, session))
  }, domain = session)
  invisible(obs)
}

task_error <- function(rec) {
  errs <- Filter(Negate(is.null), c(list(rec$error), lapply(rec$steps, function(s) s$error)))
  if (length(errs)) errs[[1]] else "no details were recorded"
}

task_status_ui <- function(t, what) {
  if (is.null(t)) return(NULL)
  if (t$state %in% c("queued", "running")) {
    return(shiny::p(class = "hint task-running",
      sprintf("%s is running in the background as %s. Keep using the app; the result appears here, and the Pipeline panel lists it.", what, t$id)))
  }
  if (!identical(t$state, "succeeded")) {
    return(shiny::p(class = "text-danger small", sprintf("%s %s: %s", what, t$state, t$error %||% "")))
  }
  NULL
}
