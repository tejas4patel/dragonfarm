# Admin: the policy in the app. Which tools each agent may use, what waits
# for a person, where data may go, the four-eyes rule and the budgets. Saving
# writes a new, append-only policy version with who changed it and why;
# older versions stay readable. The page is read-only when
# options(dragonfarm.admin = FALSE), which a shared deployment sets for
# everyone who is not an admin.


# Admins, admin groups and access rules as plain text in the card: names
# separated by commas, and one access rule per line, "set | documents | groups".
names_from_text <- function(x) {
  v <- trimws(unlist(strsplit(x %||% "", ",")))
  as.list(v[nzchar(v)])
}

access_to_text <- function(rules) {
  paste(vapply(rules %||% list(), function(r) sprintf("%s | %s | %s", r$set %||% "*", r$documents %||% "*",
                                                      paste(c(unlist(r$groups), unlist(r$users)), collapse = ", ")), ""),
        collapse = "\n")
}

access_from_text <- function(x) {
  lines <- trimws(unlist(strsplit(x %||% "", "[\r\n]+")))
  lapply(lines[nzchar(lines)], function(l) {
    parts <- trimws(strsplit(l, "|", fixed = TRUE)[[1]])
    if (length(parts) != 3) cli::cli_abort("Each access rule needs three parts: set | documents | groups. Not: {.val {l}}.")
    rule <- list(documents = parts[2], groups = names_from_text(parts[3]))
    if (!identical(parts[1], "*")) rule$set <- parts[1]
    rule
  })
}

mod_policy_ui <- function(id) {
  ns <- shiny::NS(id)
  bslib::card(
    bslib::card_header(shiny::span("Policy"), shiny::uiOutput(ns("version_pill"), inline = TRUE)),
    shiny::p(class = "hint", "What agents may do, what waits for a person, and where data may go. Each save is a new version; nothing is overwritten."),
    shiny::uiOutput(ns("form")),
    shiny::tags$h6("History"),
    shiny::div(class = "table-wrap", shiny::tableOutput(ns("history")))
  )
}

# The policy the form describes: the current one with the form's choices.
policy_from_inputs <- function(current, input) {
  p <- current
  p$version <- NULL
  for (a in names(p$agents)) p$agents[[a]]$tools <- as.list(input[[paste0("agent_", a)]] %||% character())
  p$approvals$tools <- as.list(input$approve_tools %||% character())
  p$approvals$side_effects <- as.list(input$approve_effects %||% character())
  hosts <- trimws(unlist(strsplit(input$hosts %||% "", "[\r\n,]+")))
  p$outbound$allowed_hosts <- switch(input$outbound %||% "any", any = NULL, none = list(), only = as.list(hosts[nzchar(hosts)]))
  p$registry$separate_signer <- isTRUE(input$separate_signer)
  p$registry$governed <- isTRUE(input$governed)
  if (!is.null(input$admins)) p$admins <- names_from_text(input$admins)
  if (!is.null(input$admin_groups)) p$admin_groups <- names_from_text(input$admin_groups)
  if (!is.null(input$access)) p$access <- access_from_text(input$access)
  p$budgets$max_steps <- as.integer(input$max_steps %||% p$budgets$max_steps)
  p$budgets$max_gpu_minutes <- as.integer(input$max_gpu_minutes %||% p$budgets$max_gpu_minutes)
  p
}

mod_policy_server <- function(id, runs_dir) {
  shiny::moduleServer(id, function(input, output, session) {
    ns <- session$ns
    tick <- shiny::reactiveVal(0)
    current <- shiny::reactive({ tick(); policy_current(runs_dir) })
    tools <- names(tool_registry())

    output$version_pill <- shiny::renderUI({
      shiny::span(class = "pill succeeded", sprintf("version %d", current()$version))
    })

    output$form <- shiny::renderUI({
      p <- current()
      admin <- policy_admin()
      hosts <- p$outbound$allowed_hosts
      mode <- if (is.null(hosts)) "any" else if (!length(unlist(hosts))) "none" else "only"
      form <- shiny::tagList(
        shiny::tags$h6("Tools each agent may use"),
        lapply(names(p$agents), function(a) shiny::checkboxGroupInput(ns(paste0("agent_", a)), a, choices = tools,
                                                                      selected = unlist(p$agents[[a]]$tools), inline = TRUE)),
        shiny::tags$h6("Waits for a person"),
        shiny::checkboxGroupInput(ns("approve_tools"), "These tools", choices = tools, selected = unlist(p$approvals$tools), inline = TRUE),
        shiny::checkboxGroupInput(ns("approve_effects"), "Anything that", inline = TRUE,
                                  choices = c("writes" = "writes", "cannot be undone" = "irreversible", "leaves this machine" = "outbound"),
                                  selected = unlist(p$approvals$side_effects)),
        shiny::tags$h6("Where data may go"),
        shiny::radioButtons(ns("outbound"), NULL, inline = TRUE, selected = mode,
                            choices = c("Any host (each call recorded)" = "any", "Nowhere" = "none", "Only these hosts" = "only")),
        shiny::textAreaInput(ns("hosts"), "Hosts, one per line (*.example.com allows subdomains)",
                             value = paste(unlist(hosts), collapse = "\n"), rows = 3, width = "100%"),
        shiny::tags$h6("Sign-off and budgets"),
        shiny::checkboxInput(ns("separate_signer"), "A model version must be signed by someone other than its proposer",
                             value = isTRUE(p$registry$separate_signer)),
        shiny::checkboxInput(ns("governed"), "Only approved model versions answer questions (trained runs need a sign-off first)",
                             value = isTRUE(p$registry$governed)),
        shiny::p(class = "hint small", "Until saved here, both are on for a server (Posit Connect or a shared catalogue) and off on a single laptop."),
        shiny::tags$h6("People and documents"),
        bslib::layout_columns(col_widths = c(6, 6),
          shiny::textInput(ns("admins"), "Admins (names, comma-separated)", value = paste(unlist(p$admins), collapse = ", "), width = "100%"),
          shiny::textInput(ns("admin_groups"), "Admin groups (from your sign-in service)", value = paste(unlist(p$admin_groups), collapse = ", "), width = "100%")),
        shiny::p(class = "hint small", "With no admins or groups named, anyone using this app may change the policy, as on a laptop."),
        shiny::textAreaInput(ns("access"), "Who may see which documents: one rule per line, set | documents | groups (for example: sops | hr-*.pdf | hr)",
                             value = access_to_text(p$access), rows = 3, width = "100%"),
        bslib::layout_columns(col_widths = c(6, 6),
          shiny::numericInput(ns("max_steps"), "Steps per agent task", value = p$budgets$max_steps %||% 30, min = 1),
          shiny::numericInput(ns("max_gpu_minutes"), "GPU minutes per agent task", value = p$budgets$max_gpu_minutes %||% 120, min = 1)),
        if (admin) shiny::tagList(
          shiny::textInput(ns("why"), "Why this change", width = "100%"),
          shiny::actionButton(ns("save"), "Save as a new version", class = "btn-primary"))
        else shiny::p(class = "hint", "Only an admin can change the policy here.")
      )
      if (admin) form else shiny::tags$fieldset(disabled = "disabled", form)
    })

    shiny::observeEvent(input$save, {
      if (!policy_admin()) return()
      why <- trimws(input$why %||% "")
      if (!nzchar(why)) { shiny::showNotification("Say why, so the next person knows.", type = "warning"); return() }
      new <- tryCatch(policy_from_inputs(current(), input), error = function(e) { notify_error(e); NULL })
      if (is.null(new)) return()
      # Never lock everyone out: the person saving must still be an admin.
      if (!policy_admin(policy = new)) {
        shiny::showNotification("Not saved: you would no longer be an admin. Add your name or one of your groups.", type = "warning", duration = 10)
        return()
      }
      v <- tryCatch(policy_set(new, note = why, runs_dir = runs_dir), error = function(e) { notify_error(e); NULL })
      if (!is.null(v)) {
        shiny::showNotification(sprintf("Policy version %d saved.", v), type = "message")
        shiny::updateTextInput(session, "why", value = "")
        tick(tick() + 1)
      }
    })

    output$history <- shiny::renderTable({
      tick()
      h <- tryCatch(policy_history(runs_dir), error = function(e) NULL)
      if (is.null(h) || !nrow(h)) return(data.frame(Note = "No versions yet."))
      data.frame(Version = h$version, `Set by` = h$set_by, When = sub("T", " ", sub("Z$", "", h$set_at)),
                 Why = ifelse(is.na(h$note), "", h$note), check.names = FALSE)
    })
  })
}
