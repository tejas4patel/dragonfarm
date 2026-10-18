# Who is acting: the signed-in user on a server, else the operating-system
# user; and who may change the policy.

test_that("the signed-in user is named, falling back to the option and the OS user", {
  expect_equal(dragonfarm:::current_user(list(user = "jo.lee")), "jo.lee")
  withr::local_options(dragonfarm.user = "svc-review")
  expect_equal(dragonfarm:::current_user(list(user = NULL)), "svc-review")
  withr::local_options(dragonfarm.user = NULL)
  expect_equal(dragonfarm:::current_user(NULL), Sys.info()[["user"]])
  expect_equal(dragonfarm:::current_groups(list(groups = c("qa", "stats"))), c("qa", "stats"))
  expect_equal(dragonfarm:::current_groups(NULL), character())
})

test_that("the record, proposals, sign-offs and policy versions name the signed-in user", {
  runs <- withr::local_tempdir()
  withr::local_options(dragonfarm.runs_dir = runs, dragonfarm.user = "jo.lee")
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  dragonfarm:::store_record_event("probe", "x", ok = TRUE, runs_dir = runs)
  expect_equal(dragonfarm:::store_events(1, runs_dir = runs)$actor, "jo.lee")
  dragonfarm:::policy_set(dragonfarm:::policy_default(), runs_dir = runs)
  expect_equal(dragonfarm:::policy_history(runs)$set_by[1], "jo.lee")
})

test_that("named admins and admin groups decide who may change the policy", {
  pol <- dragonfarm:::policy_default()
  withr::local_options(dragonfarm.admin = NULL)
  expect_true(dragonfarm:::policy_admin(list(user = "anyone"), pol))           # no admins named: as on a laptop
  pol$admins <- list("jo.lee"); pol$admin_groups <- list("dragonfarm-admins")
  expect_true(dragonfarm:::policy_admin(list(user = "jo.lee"), pol))
  expect_false(dragonfarm:::policy_admin(list(user = "sam.k", groups = "stats"), pol))
  expect_true(dragonfarm:::policy_admin(list(user = "sam.k", groups = c("stats", "dragonfarm-admins")), pol))
  expect_equal(dragonfarm:::policy_problems(pol), character())
  pol$admins <- list(42)
  expect_match(dragonfarm:::policy_problems(pol), "admins")
})
