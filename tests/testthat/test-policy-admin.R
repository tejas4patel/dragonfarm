test_that("an admin changes the policy in the app; each save is a new version with its reason", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs, dragonfarm.admin = NULL)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  shiny::testServer(dragonfarm:::mod_policy_server, args = list(runs_dir = runs), {
    expect_match(output$version_pill$html, "version 1")
    session$setInputs(agent_ops = c("list_runs"), approve_tools = c("train_model", "promote_model"),
                      approve_effects = c("irreversible", "outbound"), outbound = "only",
                      hosts = "api.anthropic.com\n*.huggingface.co", separate_signer = TRUE,
                      max_steps = 12, max_gpu_minutes = 60, why = "")
    session$setInputs(save = 1)
    expect_equal(dragonfarm:::policy_current(runs)$version, 1L)          # no reason, no save
    session$setInputs(why = "Pharma pilot: four eyes and known hosts only", save = 2)
    p <- dragonfarm:::policy_current(runs)
    expect_equal(p$version, 2L)
    expect_equal(unlist(p$agents$ops$tools), "list_runs")
    expect_equal(unlist(p$outbound$allowed_hosts), c("api.anthropic.com", "*.huggingface.co"))
    expect_true(p$registry$separate_signer); expect_equal(p$budgets$max_steps, 12)
    expect_equal(p$agents$answer$min_model_b, 7)                         # what the form does not show is kept
    expect_match(output$history, "Pharma pilot")
    expect_match(output$version_pill$html, "version 2")
  })
  expect_error(dragonfarm:::outbound_check("https://api.groq.com", "test", runs_dir = runs), class = "dragonfarm_error")
  h <- dragonfarm:::policy_history(runs)
  expect_equal(h$version, 2:1); expect_equal(h$note[1], "Pharma pilot: four eyes and known hosts only")
})

test_that("outbound choices map to the policy: any, none, only these", {
  cur <- dragonfarm:::policy_default()
  f <- function(...) dragonfarm:::policy_from_inputs(cur, list(...))
  expect_null(f(outbound = "any")$outbound$allowed_hosts)
  expect_length(f(outbound = "none")$outbound$allowed_hosts, 0)
  expect_equal(unlist(f(outbound = "only", hosts = "a.com, b.com")$outbound$allowed_hosts), c("a.com", "b.com"))
})

test_that("without admin rights the policy is shown but cannot be saved", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs, dragonfarm.admin = FALSE)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  shiny::testServer(dragonfarm:::mod_policy_server, args = list(runs_dir = runs), {
    expect_match(output$form$html, "disabled")
    expect_match(output$form$html, "Only an admin")
    session$setInputs(why = "sneaky", outbound = "any", save = 1)
    expect_equal(dragonfarm:::policy_current(runs)$version, 1L)
  })
})
