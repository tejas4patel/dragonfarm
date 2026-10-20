# Settings: the keys for outside services, entered once and kept in the
# computer's keychain. One card per service, each with a status, a link to
# where the key is made, a masked field, Save (which also checks the key),
# and Remove. Sign-in always happens on the provider's own site in the
# system browser; nothing here embeds it.

mod_settings_ui <- function(id) {
  ns <- shiny::NS(id)
  cards <- lapply(names(secret_catalog()), function(svc) settings_card_ui(ns, svc))
  shiny::tagList(
    shiny::uiOutput(ns("keychain_note")),
    do.call(bslib::layout_columns, c(list(col_widths = c(6, 6)), cards)),
    mod_policy_ui(ns("policy")),
    bslib::card(
      bslib::card_header("Qualification report"),
      shiny::p(class = "hint", "Checks that dragonfarm is installed as specified and that its controls work (the record refuses edits, agents stay within the policy, blocked data stays put, and more), on throwaway data. You get a dated report with every check and its evidence; its fingerprint goes into the record."),
      shiny::downloadButton(ns("qualify"), "Run the checks and download the report", class = "btn-outline-primary")
    ),
    bslib::card(
      bslib::card_header("Free tiers"),
      shiny::p(class = "hint", "When this machine is too small for a model, a free-tier provider can answer instead. Nothing is sent there until you opt in, and you can cap how many requests a day it gets."),
      shiny::uiOutput(ns("free_tiers"))
    )
  )
}

settings_card_ui <- function(ns, svc) {
  s <- secret_catalog()[[svc]]
  fields <- lapply(s$vars, function(v) shiny::passwordInput(ns(paste0("val_", v)), settings_label(v), width = "100%"))
  bslib::card(
    bslib::card_header(shiny::span(s$title), shiny::uiOutput(ns(paste0("pill_", svc)), inline = TRUE)),
    shiny::p(class = "hint", s$why),
    shiny::tags$a(href = s$get_url, target = "_blank", rel = "noopener", class = "small",
                  if (identical(svc, "kaggle")) "Get my key: Settings > API > Generate New Token" else "Get my key"),
    if (identical(svc, "kaggle")) shiny::uiOutput(ns("kaggle_found")),
    fields,
    shiny::div(class = "btn-row",
      shiny::actionButton(ns(paste0("save_", svc)), "Save and check", class = "btn-primary btn-sm"),
      shiny::actionButton(ns(paste0("remove_", svc)), "Remove", class = "btn-outline-secondary btn-sm")),
    shiny::uiOutput(ns(paste0("msg_", svc)))
  )
}

settings_label <- function(var) {
  switch(var, HF_TOKEN = "Access token", ANTHROPIC_API_KEY = "API key", KAGGLE_USERNAME = "Username",
         KAGGLE_KEY = "Key or API token", LIGHTNING_USER_ID = "User id", LIGHTNING_API_KEY = "API key", "API key")
}

settings_pill <- function(st) {
  if (!isTRUE(st$set)) return(shiny::span(class = "pill cancelled", "not set"))
  shiny::span(class = "pill succeeded", if (identical(st$where, "keychain")) paste("saved", st$masked) else paste("set by your admin", st$masked))
}

mod_settings_server <- function(id, runs_dir) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns
    mod_policy_server("policy", runs_dir)
    output$qualify <- shiny::downloadHandler(
      filename = function() sprintf("dragonfarm-qualification-%s.md", format(Sys.time(), "%Y%m%d-%H%M%S")),
      content = function(file) {
        r <- qualification_report(file, runs_dir = runs_dir)
        shiny::showNotification(sprintf("Checks done: %d passed, %d failed.", r$passed, r$failed),
                                type = if (r$failed) "warning" else "message")
      },
      contentType = "text/markdown"
    )
    tick <- shiny::reactiveVal(0)     # bumped after every save or remove
    messages <- shiny::reactiveValues()

    output$keychain_note <- shiny::renderUI({
      problem <- keychain_problem()
      if (is.null(problem)) return(NULL)
      shiny::div(class = "alert alert-warning small", "Keys cannot be saved on this computer yet. ", problem)
    })

    for (svc in names(secret_catalog())) local({
      svc <- svc
      vars <- secret_catalog()[[svc]]$vars
      output[[paste0("pill_", svc)]] <- shiny::renderUI({ tick(); settings_pill(secret_status(svc)) })
      output[[paste0("msg_", svc)]] <- shiny::renderUI({
        m <- messages[[svc]]
        if (is.null(m)) return(NULL)
        shiny::p(class = paste("small", if (isTRUE(m$ok)) "text-success" else if (isFALSE(m$ok)) "text-danger" else "text-muted"), m$message)
      })
      shiny::observeEvent(input[[paste0("save_", svc)]], {
        values <- stats::setNames(lapply(vars, function(v) input[[paste0("val_", v)]]), vars)
        ok <- tryCatch({ secret_save(svc, values); TRUE }, error = function(e) { messages[[svc]] <- list(ok = FALSE, message = conditionMessage(e)); FALSE })
        if (!ok) return()
        for (v in vars) shiny::updateTextInput(session, paste0("val_", v), value = "")
        messages[[svc]] <- tryCatch(secret_check(svc), error = function(e) list(ok = NA, message = paste("Saved; the check could not run:", conditionMessage(e))))
        tick(tick() + 1)
      })
      shiny::observeEvent(input[[paste0("remove_", svc)]], {
        secret_remove(svc)
        messages[[svc]] <- list(ok = NA, message = "Removed from this computer.")
        tick(tick() + 1)
      })
    })

    # Kaggle hands out its key as a downloaded kaggle.json: pick it up.
    found <- shiny::reactive({
      tick()
      shiny::invalidateLater(4000)
      if (isTRUE(secret_status("kaggle")$set)) return(NULL)
      kaggle_json_download()
    })
    output$kaggle_found <- shiny::renderUI({
      k <- found()
      if (is.null(k)) return(NULL)
      shiny::div(class = "small",
        sprintf("Found %s in your Downloads folder (user %s). ", basename(k$path), k$username),
        shiny::actionButton(ns("kaggle_use"), "Use it", class = "btn-primary btn-sm"))
    })
    shiny::observeEvent(input$kaggle_use, {
      k <- found()
      if (is.null(k)) return()
      ok <- tryCatch({ secret_save("kaggle", list(KAGGLE_USERNAME = k$username, KAGGLE_KEY = k$key)); TRUE },
                     error = function(e) { messages$kaggle <- list(ok = FALSE, message = conditionMessage(e)); FALSE })
      if (!ok) return()
      check <- tryCatch(secret_check("kaggle"), error = function(e) list(ok = NA, message = "Saved."))
      messages$kaggle <- list(ok = check$ok, message = paste(check$message, sprintf("You can delete %s from Downloads now; the key is in your keychain.", basename(k$path))))
      tick(tick() + 1)
    })

    output$free_tiers <- shiny::renderUI({
      tick()
      rows <- lapply(names(provider_catalog()), function(p) {
        st <- tryCatch(provider_status(p, runs_dir), error = function(e) list(opted_in = FALSE, used_today = 0L))
        info <- provider_info(p)
        shiny::div(class = "free-tier",
          shiny::strong(info$title), " ",
          if (isTRUE(st$opted_in)) shiny::span(class = "pill succeeded", sprintf("on, %d requests today%s", st$used_today,
                                                                              if (!is.null(st$daily_cap)) sprintf(" of %d", st$daily_cap) else ""))
          else shiny::span(class = "pill cancelled", "off"),
          shiny::p(class = "hint", info$free_models_note),
          if (isTRUE(st$opted_in)) shiny::actionButton(ns(paste0("optout_", p)), "Turn off", class = "btn-outline-secondary btn-sm")
          else shiny::tagList(
            shiny::numericInput(ns(paste0("cap_", p)), "Daily cap (requests)", value = 50, min = 1, step = 10, width = "200px"),
            shiny::checkboxInput(ns(paste0("agree_", p)), sprintf("I agree to send my questions and the excerpts they use to %s.", info$title)),
            shiny::actionButton(ns(paste0("optin_", p)), "Turn on", class = "btn-primary btn-sm")))
      })
      shiny::tagList(rows)
    })
    for (p in names(provider_catalog())) local({
      p <- p
      shiny::observeEvent(input[[paste0("optin_", p)]], {
        if (!isTRUE(input[[paste0("agree_", p)]])) {
          shiny::showNotification("Tick the box to agree first.", type = "warning")
          return()
        }
        provider_opt_in(p, daily_cap = input[[paste0("cap_", p)]], runs_dir = runs_dir)
        tick(tick() + 1)
      })
      shiny::observeEvent(input[[paste0("optout_", p)]], {
        provider_opt_out(p, runs_dir = runs_dir)
        tick(tick() + 1)
      })
    })
  })
}
