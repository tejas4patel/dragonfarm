# A check of an answer against the excerpts it was written from, with no
# model: every citation points at an excerpt that was given, and every
# figure in the answer (numbers, dates, percentages, versions) appears in
# the excerpts it cites, or in the question. A 7B asked to check answers
# was tried and gave no gain; this is the deterministic part that can be
# trusted. It cannot tell whether words are right, only whether figures
# came from somewhere.

# Citation numbers in a reply: "[1]", "[1, 3]", "[2][4]", "[1-2]".
answer_citations <- function(answer) {
  inner <- regmatches(answer, gregexpr("\\[[0-9][0-9 ,;-]*\\]", answer))[[1]]
  n <- integer()
  for (x in gsub("[][ ]", "", inner)) {
    for (part in strsplit(x, "[,;]")[[1]]) {
      ends <- suppressWarnings(as.integer(strsplit(part, "-")[[1]]))
      ends <- ends[!is.na(ends)]
      if (length(ends) == 2 && ends[2] >= ends[1] && ends[2] - ends[1] < 20) n <- c(n, seq(ends[1], ends[2]))
      else n <- c(n, ends)
    }
  }
  sort(unique(n))
}

# Figures as written, with thousands separators dropped: "1,200" -> "1200",
# "4.12.2", "30", "2.5%". Single digits are left out: "one of 3 options" is
# too common to be a claim worth checking, and list markers look the same.
answer_figures <- function(text) {
  text <- gsub("\\[[0-9][0-9 ,;-]*\\]", " ", text)
  x <- regmatches(text, gregexpr("(?<![A-Za-z0-9.])[0-9][0-9,]*(?:[.][0-9]+)*%?", text, perl = TRUE))[[1]]
  x <- gsub("(?<=[0-9]),(?=[0-9]{3})", "", x, perl = TRUE)
  x <- sub("[.,]+$", "", x)
  x <- sub("%$", "", x)
  unique(x[nchar(gsub("[^0-9]", "", x)) >= 2])
}

figure_in <- function(fig, text) {
  text <- gsub("(?<=[0-9]),(?=[0-9]{3})", "", text, perl = TRUE)
  found <- function(f, after = "") grepl(sprintf("(?<![0-9.])%s(?![0-9])%s", gsub(".", "[.]", f, fixed = TRUE), after), text, perl = TRUE)
  if (found(fig)) return(TRUE)
  # The same share written the other way: "0.22" for "22%", "7%" for "0.07".
  v <- suppressWarnings(as.numeric(fig))
  if (is.na(v)) return(FALSE)
  pct <- format(round(v * 100, 6), scientific = FALSE, drop0trailing = TRUE, trim = TRUE)
  dec <- format(round(v / 100, 8), scientific = FALSE, drop0trailing = TRUE, trim = TRUE)
  (v < 1 && found(pct, " ?(%|percent)")) || found(dec)
}

# answer: the reply. sources: a data frame with n and text (dragon_ask()'s
# $sources). Returns a list: ok, declined, citations, bad_citations,
# figures, ungrounded (figures found in no cited excerpt nor the question).
answer_check <- function(answer, sources, question = "") {
  answer <- answer %||% ""
  declined <- answer_declines(answer)
  cites <- answer_citations(answer)
  bad <- setdiff(cites, sources$n)
  used <- if (length(intersect(cites, sources$n))) sources$text[sources$n %in% cites] else sources$text
  figs <- answer_figures(answer)
  ground <- paste(c(used, question), collapse = "\n")
  ungrounded <- figs[!vapply(figs, figure_in, TRUE, text = ground)]
  list(ok = !length(bad) && !length(ungrounded), declined = declined, citations = cites,
       bad_citations = bad, figures = figs, ungrounded = ungrounded)
}

# Under an answer in the app: quiet when the check passes, one plain line
# when it does not.
check_note <- function(a) {
  if (is.null(a$sources) || !"text" %in% names(a$sources)) return(NULL)
  r <- tryCatch(answer_check(a$answer, a$sources, a$question %||% ""), error = function(e) NULL)
  if (is.null(r) || r$ok) return(NULL)
  bits <- c(
    if (length(r$ungrounded)) sprintf("%s %s not in the excerpts", paste(r$ungrounded, collapse = ", "),
                                     if (length(r$ungrounded) == 1) "is" else "are"),
    if (length(r$bad_citations)) sprintf("%s %s to no excerpt", paste0("[", r$bad_citations, "]", collapse = ", "),
                                        if (length(r$bad_citations) == 1) "points" else "point")
  )
  shiny::p(class = "check-note small text-warning", paste0("Check this: ", paste(bits, collapse = "; "), "."))
}
