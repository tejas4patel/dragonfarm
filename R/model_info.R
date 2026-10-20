# What each model size does, measured, shown next to every model choice in
# the app. The numbers are the ones in the "Choosing a model size" article
# (Qwen 2.5 Instruct on an 8 GB laptop RTX 4060; answering re-measured on
# 2026-10-19); keep the two in step when re-measuring.

model_comparison <- function(task = c("answer", "questions", "train")) {
  task <- match.arg(task)
  switch(task,
    answer = data.frame(
      Model = c("0.5B", "1.5B", "3B", "7B, 4-bit"),
      `Wrong or empty (of 55)` = c(16, 9, 4, 2),
      `Says "not covered" (of 20)` = c(14, 20, 20, 20),
      `Seconds per answer` = c(1.0, 1.2, 5.1, 7.7),
      Needs = c("any machine", "any machine", "6 GB GPU", "8 GB NVIDIA"),
      check.names = FALSE, stringsAsFactors = FALSE
    ),
    questions = data.frame(
      Model = c("0.5B", "1.5B", "3B", "7B, 4-bit"),
      `Pairs kept (of 120)` = c(18, 51, 82, 104),
      `Correct when checked (of 12)` = c(6, 11, 10, 12),
      `Minutes for 40 chunks` = c(2.0, 2.6, 3.2, 3.9),
      check.names = FALSE, stringsAsFactors = FALSE
    ),
    train = data.frame(
      Model = c("0.5B", "1.5B", "3B, 4-bit", "7B, 4-bit"),
      `Documents: bad answers (of 47)` = c("6", "4", "2", "\u2013"),
      `Tickets to JSON (of 20)` = c(20, 20, 20, 20),
      `Training time, 616 document pairs` = c("21 min", "36 min", "66 min", "4 h 19 min"),
      `Peak GPU memory` = c("6.2 GB", "\u2013", "4.3 GB", "7.9 GB"),
      check.names = FALSE, stringsAsFactors = FALSE
    )
  )
}

model_comparison_text <- list(
  answer = c(title = "Answering from documents, by model size",
             note = paste("Untrained models, 55 questions with known answers and 20 the documents do not cover",
                          "(an annual report and R's manuals). The 3B and 7B give full answers, so they take longer;",
                          "smaller models answer in a sentence or two and are wrong more often.")),
  questions = c(title = "Writing training questions, by model size",
                note = paste("Three questions from each of 40 chunks of R's manuals; kept by the filters, then",
                             "twelve checked by hand against the source. The 7B's were all correct.")),
  train = c(title = "Fine-tuning, by model size",
            note = paste("Documents: tuned on R's manuals with the default \"not covered\" rows, wrong, made-up,",
                         "or wrongly declined answers of 47 (the 7B was not retrained with them).",
                         "For a fixed format such as JSON, every size reaches the same score."))
)

model_comparison_table <- function(task) {
  df <- model_comparison(task)
  shiny::tags$table(class = "df-cmp",
    shiny::tags$thead(shiny::tags$tr(lapply(names(df), shiny::tags$th))),
    shiny::tags$tbody(lapply(seq_len(nrow(df)), function(i) {
      shiny::tags$tr(lapply(df[i, ], function(v) shiny::tags$td(format(v))))
    }))
  )
}

# An (i) icon that shows the comparison on hover or keyboard focus.
model_info_icon <- function(task = c("answer", "questions", "train")) {
  task <- match.arg(task)
  txt <- model_comparison_text[[task]]
  icon <- shiny::tags$span(
    class = "df-info", tabindex = "0", role = "button",
    `aria-label` = paste0(txt[["title"]], ": show the comparison"),
    shiny::HTML(paste0('<svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true">',
                       '<circle cx="8" cy="8" r="7" fill="none" stroke="currentColor" stroke-width="1.5"/>',
                       '<circle cx="8" cy="4.8" r="1" fill="currentColor"/>',
                       '<rect x="7.25" y="6.8" width="1.5" height="5" rx="0.75" fill="currentColor"/></svg>'))
  )
  bslib::popover(
    icon,
    model_comparison_table(task),
    shiny::tags$p(class = "df-cmp-note", txt[["note"]]),
    shiny::tags$p(class = "df-cmp-note", "Measured on an 8 GB laptop GPU. Details: \"Choosing a model size\" on dragonfarm.dev."),
    title = txt[["title"]],
    placement = "right",
    options = list(trigger = "hover focus", customClass = "df-popover")
  )
}

# A label with the icon after it, for selectInput() and card headers.
label_with_info <- function(label, task) {
  shiny::tags$span(class = "df-label-info", label, model_info_icon(task))
}
