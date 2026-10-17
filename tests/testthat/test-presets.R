
test_that("presets pin a Hub commit and runs and answers use it", {
  p <- dragon_presets()
  expect_true(all(grepl("^[0-9a-f]{40}$", p$revision)))
  expect_equal(dragonfarm:::preset_revision("Qwen/Qwen2.5-7B-Instruct"), "a09a35458c702b33eeacc393d103063234e8bc28")
  expect_null(dragonfarm:::preset_revision("someone/other-model"))
  expect_equal(dragonfarm:::resolve_target("Qwen/Qwen2.5-3B-Instruct")$revision, p$revision[p$id == "Qwen/Qwen2.5-3B-Instruct"])
  expect_null(dragonfarm:::resolve_target("someone/other-model")$revision)
  cfg <- dragonfarm:::build_config("r1", "Qwen/Qwen2.5-0.5B-Instruct", list(train = "t.jsonl"), dragon_lora(), dragon_train_args(),
                                   dragon_hardware(), 10)
  expect_equal(cfg$model$revision, "7ae557604adf67be50417f59c2c2f167def9a775")
  expect_false(cfg$model$allow_pickle)
  cfg2 <- dragonfarm:::build_config("r2", "Qwen/Qwen2.5-0.5B-Instruct", list(train = "t.jsonl"), dragon_lora(), dragon_train_args(),
                                    dragon_hardware(), 10, revision = "main")
  expect_equal(cfg2$model$revision, "main")                                   # an explicit revision wins
  expect_match(dragonfarm:::error_message("OSError: does not appear to have a file named model.safetensors", "PICKLE_WEIGHTS_ONLY"),
               "allow_pickle_weights")
})
