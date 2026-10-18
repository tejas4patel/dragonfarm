hold_list_runs <- function(runs) {
  pol <- dragonfarm:::policy_default()
  pol$approvals$tools <- c(unlist(pol$approvals$tools), "list_runs")
  dragonfarm:::policy_set(pol, set_by = "admin", runs_dir = runs)
}

test_that("a held call waits in the inbox and runs only once a person approves", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  hold_list_runs(runs)
  r <- tool_call("list_runs", list(limit = 5), agent = "ops")
  expect_equal(r$code, "NEEDS_APPROVAL")
  p <- dragonfarm:::approvals_pending(runs)
  expect_equal(nrow(p), 1)
  tab <- dragonfarm:::approvals_table(p)
  expect_equal(tab$Agent, "ops"); expect_equal(tab$Wants, "list_runs"); expect_match(tab$With, "limit = 5")

  out <- dragonfarm:::approval_decide(p$id, approve = TRUE, note = "fine", runs_dir = runs)
  expect_true(out$ok)
  expect_equal(nrow(dragonfarm:::approvals_pending(runs)), 0)
  ev <- dragonfarm:::store_events(5, runs_dir = runs)
  expect_equal(ev$kind[1:2], c("tool", "approval_decision"))
  d <- jsonlite::fromJSON(ev$detail[1])
  expect_equal(d$on_behalf_of$agent, "ops"); expect_equal(d$on_behalf_of$approval, p$id)
  expect_error(dragonfarm:::approval_decide(p$id, approve = TRUE, runs_dir = runs), "already been decided")
})

test_that("a declined call never runs", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs)
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  hold_list_runs(runs)
  tool_call("list_runs", list(), agent = "ops")
  id <- dragonfarm:::approvals_pending(runs)$id
  out <- dragonfarm:::approval_decide(id, approve = FALSE, runs_dir = runs)
  expect_true(out$declined)
  ev <- dragonfarm:::store_events(10, runs_dir = runs)
  expect_false(any(ev$kind == "tool" & ev$ok == 1))
  expect_equal(nrow(dragonfarm:::approvals_pending(runs)), 0)
  expect_match(dragonfarm:::approvals_table(dragonfarm:::approvals_pending(runs))$Note, "Nothing is waiting")
})

test_that("only requests can be decided", {
  runs <- withr::local_tempdir()
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  dragonfarm:::store_record_event("tool", "list_runs", ok = TRUE, runs_dir = runs)
  id <- dragonfarm:::store_events(1, runs_dir = runs)$id
  expect_error(dragonfarm:::approval_decide(id, approve = TRUE, runs_dir = runs), class = "dragonfarm_error")
})
