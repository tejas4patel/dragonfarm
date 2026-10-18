# Planted personal data, and look-alikes that must not be flagged.
pii_planted <- c(
  "Contact the study nurse at jane.doe@hospital.org or (617) 555-0142 with questions.",
  "Patient ID: AB-77231 enrolled on day 3; MRN 00451237 was transferred.",
  "Date of birth: 04/12/1961. SSN 123-45-6789 appears on the intake form.",
  "Card 4111 1111 1111 1111 was charged; reference 4111 1111 1111 1112 was not a card.",
  "DOB 1975-08-30 recorded at screening; born on March 3, 1988 per the second form.",
  "Call +1 202-555-0198 for the site monitor, or (800)249-8982 after hours."
)
pii_lookalikes <- c(
  "Version 4.12.2 fixes the sync issue; R 4.6.1 was released in 2026.",
  "Net sales were $249,625 million in fiscal 2024, up 5.0% from 237,710.",
  "The guidance was issued in May 2023 and revised on 2021-05-01.",
  "Table 1: odds ratio 4.8 with 95% CI 3.1 to 7.2; 1,234,567 rows in total.",
  "ISBN 978-0-13-468599-1 and DOI 10.1080/01621459.2021.1981338 are cited.",
  "Section 21 CFR 11.10 applies to records kept for 12 months."
)

test_that("planted personal data is found, by type", {
  hits <- do.call(rbind, lapply(pii_planted, dragonfarm:::pii_find))
  expect_equal(sort(unique(hits$type)), sort(c("email", "phone", "record_id", "birth_date", "ssn", "card")))
  expect_equal(sum(hits$type == "email"), 1)
  expect_equal(sum(hits$type == "phone"), 3)
  expect_equal(sum(hits$type == "record_id"), 2)
  expect_equal(sum(hits$type == "birth_date"), 3)
  expect_equal(sum(hits$type == "ssn"), 1)
  expect_equal(sum(hits$type == "card"), 1)              # the number failing the Luhn check is not a card
})

test_that("numbers that only look like personal data are left alone", {
  hits <- do.call(rbind, lapply(pii_lookalikes, dragonfarm:::pii_find))
  expect_equal(nrow(hits), 0)
})

test_that("redaction replaces each hit with its type", {
  r <- vapply(pii_planted, dragonfarm:::pii_redact, "", USE.NAMES = FALSE)
  expect_match(r[1], "[EMAIL]", fixed = TRUE); expect_match(r[1], "[PHONE]", fixed = TRUE)
  expect_false(grepl("jane.doe|555-0142|123-45-6789|4111 1111 1111 1111|04/12/1961", paste(r, collapse = " ")))
  expect_match(r[4], "1111 1112", fixed = TRUE)          # not a card, so kept
  expect_equal(vapply(pii_lookalikes, dragonfarm:::pii_redact, "", USE.NAMES = FALSE), pii_lookalikes)
})

test_that("scanning a set lists hits with their chunk and records only counts", {
  f <- write_fake_set()
  runs <- dirname(dirname(f$dir))
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  chunks <- jsonlite::stream_in(file(file.path(f$dir, "chunks.jsonl")), verbose = FALSE)
  chunks$text[1] <- "Questions to jane.doe@hospital.org please."
  dragonfarm:::write_jsonl(lapply(seq_len(nrow(chunks)), function(i) as.list(chunks[i, ])), file.path(f$dir, "chunks.jsonl"))
  s <- dragonfarm:::pii_scan(dragon_documents_load(f$dir), runs_dir = runs)
  expect_equal(nrow(s), 1); expect_equal(s$chunk, "abc-000"); expect_equal(attr(s, "counts")[["email"]], 1)
  ev <- dragonfarm:::store_events(1, runs_dir = runs)
  expect_equal(ev$kind, "pii_scan"); expect_false(grepl("jane.doe", ev$detail))
})

test_that("the Documents step and the ingestion agent can check a set for personal data", {
  f <- write_fake_set()
  runs <- dirname(dirname(f$dir))
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  chunks <- jsonlite::stream_in(file(file.path(f$dir, "chunks.jsonl")), verbose = FALSE)
  chunks$text[2] <- "Call (617) 555-0142 about Patient ID: AB-77231."
  dragonfarm:::write_jsonl(lapply(seq_len(nrow(chunks)), function(i) as.list(chunks[i, ])), file.path(f$dir, "chunks.jsonl"))
  r <- tool_call("scan_personal_data", list(set = f$dir), agent = "ingestion")
  expect_true(r$ok); expect_equal(r$result$counts$phone, 1); expect_equal(r$result$counts$record_id, 1)
  state <- shiny::reactiveValues(documents = dragon_documents_load(f$dir), route = "documents", hardware = NULL, dataset = NULL, mapped = NULL)
  testthat::local_mocked_bindings(hardware_info = function() NULL)
  shiny::testServer(dragonfarm:::mod_documents_server, args = list(state = state, nav_to = function(p) NULL, runs_dir = runs), {
    session$flushReact()
    session$setInputs(pii = 1)
    expect_match(output$pii_result$html, "1 phone numbers")
    expect_match(output$pii_result$html, "617")
  })
})
