test_that("the shipped lock was made from the current requirements", {
  path <- dragonfarm:::lock_path()
  skip_if(!nzchar(path), "no lock file")
  head <- readLines(path, n = 5)
  expect_true(any(head == paste("# requirements:", dragonfarm:::requirements_hash())),
              info = "Requirements changed: run scripts/lock_python.R")
  pins <- dragonfarm:::lock_pins()
  expect_true(all(c("torch", "transformers", "peft", "pypdf") %in% names(pins)))
})

test_that("installed packages are compared with the lock, local builds allowed", {
  pins <- c(torch = "2.14.1", numpy = "2.3.1", "python-docx" = "1.2.0")
  installed <- c(torch = "2.14.1+cu130", numpy = "2.2.0", "python-docx" = "1.2.0", extra = "1.0")
  d <- dragonfarm:::lock_drift(installed, pins)
  expect_equal(d$package, "numpy")
  expect_equal(d$locked, "2.3.1")
  expect_equal(dragonfarm:::normalise_package(c("Python_Docx", "PyYAML", "ruamel.yaml")), c("python-docx", "pyyaml", "ruamel-yaml"))
  f <- withr::local_tempfile(lines = c("# header", "numpy==2.3.1 \\", "    --hash=sha256:abc", "bitsandbytes==0.50.2 ; sys_platform != 'darwin' \\"))
  expect_equal(dragonfarm:::lock_pins(f), c(numpy = "2.3.1", bitsandbytes = "0.50.2"))
})
