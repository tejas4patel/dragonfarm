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

test_that("a person never receives a passage from a document their groups may not see", {
  f <- write_fake_set()
  runs <- dirname(dirname(f$dir))
  withr::local_options(dragonfarm.runs_dir = runs, dragonfarm.user = "sam.k")
  on.exit(dragonfarm:::store_close_all(), add = TRUE)
  pol <- dragonfarm:::policy_default()
  pol$access <- list(list(set = "kb", documents = "policy*.pdf", groups = list("hr")))
  dragonfarm:::policy_set(pol, set_by = "admin", runs_dir = runs)
  asked_k <- NULL
  testthat::local_mocked_bindings(
    worker_start = function(...) invisible(NULL),
    worker_request = function(req) {
      asked_k <<- req$k
      ids <- c("abc-000", "def-000", "abc-001")[seq_len(min(req$k, 3))]
      list(hits = lapply(req$queries, function(q) lapply(ids, function(id) list(id = id, score = 1, similarity = 1))))
    }
  )
  docs <- dragon_documents_load(f$dir)
  h <- dragon_retrieve(docs, "warranty", k = 2)
  expect_equal(asked_k, 3L)                                   # the whole set is ranked, then filtered
  expect_false(any(h$source == "policy.pdf"))                 # sam.k is not in hr
  expect_equal(h$n, seq_len(nrow(h)))
  expect_no_match(dragonfarm:::listing_for(docs, list(model = "m")) %||% "", "policy.pdf", fixed = TRUE)
  bad <- dragonfarm:::tool_call("search_documents", list(set = f$dir, query = "warranty", source = "nope.pdf"))
  expect_no_match(bad$error, "policy.pdf", fixed = TRUE)      # a hidden document is never named

  testthat::local_mocked_bindings(current_groups = function(...) "hr")
  h2 <- dragon_retrieve(docs, "warranty", k = 2)
  expect_true(any(h2$source == "policy.pdf"))                 # hr members see it
  pol$access <- list(list(set = "kb", documents = "x.pdf"))
  expect_match(dragonfarm:::policy_problems(pol), "access rule")
})
