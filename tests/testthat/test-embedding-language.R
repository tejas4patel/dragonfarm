# D-30: a set whose text is mostly not English is indexed with the
# multilingual model; English sets, and tables with few words, keep the
# English one.

german <- paste("Die Dosis sollte bei Patienten mit eingeschraenkter Nierenfunktion nicht erhoeht werden.",
                "Das Arzneimittel ist fuer die Behandlung von Erwachsenen bestimmt und wird einmal taeglich eingenommen.",
                "Bei Kindern und Jugendlichen ist die Sicherheit nicht erwiesen, daher wird die Anwendung nicht empfohlen.",
                "Die Tabletten werden mit einem Glas Wasser zu den Mahlzeiten oder unabhaengig davon eingenommen.",
                "Wenn eine Dosis vergessen wurde, ist die naechste Dosis zur gewohnten Zeit einzunehmen und nicht zu verdoppeln.")
english <- paste("The dose should not be increased in patients with reduced kidney function.",
                 "This medicine is for the treatment of adults and is taken once a day with or without food.",
                 "The safety in children and adolescents has not been shown, so its use is not recommended.",
                 "If a dose is missed, the next dose should be taken at the usual time and not doubled.",
                 "Tell your doctor if you have any of the side effects listed in this leaflet or any that are not.")
table_text <- paste(rep("Alabama 5108468 Alaska 733406 Arizona 7431344 Arkansas 3067732 California 38965193 Colorado 5877610", 10), collapse = " ")

test_that("function-word shares tell English, German and a table apart", {
  e <- dragonfarm:::language_shares(english); g <- dragonfarm:::language_shares(german); t <- dragonfarm:::language_shares(table_text)
  expect_gt(e[["english"]], 0.15); expect_lt(e[["other"]], 0.05)
  expect_lt(g[["english"]], 0.05); expect_gt(g[["other"]], 0.12)
  expect_lt(t[["english"]], 0.08); expect_lt(t[["other"]], 0.12)        # few words of any language
  expect_true(is.na(dragonfarm:::english_share("Too short.")))
})

set_with <- function(text) {
  fake <- write_fake_set()
  dragonfarm:::write_jsonl(lapply(1:3, function(i) list(id = sprintf("abc-%03d", i), source_id = "abc", source = "a.pdf", section = "s",
                                                         text = text, n_words = 120L, quoted = FALSE, code = FALSE, weight = 1)),
                           file.path(fake$dir, "chunks.jsonl"))
  fake$dir
}

test_that("the embedding model follows the set's language", {
  expect_equal(dragonfarm:::embedding_model_for(set_with(german)), "intfloat/multilingual-e5-small")
  expect_equal(dragonfarm:::embedding_model_for(set_with(english)), "BAAI/bge-small-en-v1.5")
  expect_equal(dragonfarm:::embedding_model_for(set_with(table_text)), "BAAI/bge-small-en-v1.5")
})

test_that("dragon_index() chooses by language unless a model is named", {
  sent <- NULL
  local_mocked_bindings(worker_start = function(...) NULL,
                        worker_request = function(req) { sent <<- req$model; list(index = list(n_chunks = 3, model = req$model)) })
  de <- set_with(german)
  expect_message(dragon_index(de), "not in English")
  expect_equal(sent, "intfloat/multilingual-e5-small")
  dragon_index(set_with(english)); expect_equal(sent, "BAAI/bge-small-en-v1.5")
  dragon_index(de, model = "BAAI/bge-base-en-v1.5"); expect_equal(sent, "BAAI/bge-base-en-v1.5")   # a named model always wins
})
