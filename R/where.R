# Where things run (A11): one plain summary of this computer, the services
# with a saved key, the free tiers a person opted in to, Kaggle, and what the
# policy lets leave the machine. It only reads what is already known: no
# Python is started and nothing is contacted (keys are checked from
# Settings). Internal until the setup page settles.

where_report <- function(runs_dir = dragon_runs_dir(), hardware = the$hardware) {
  policy <- policy_current(runs_dir)
  allowed <- policy$outbound$allowed_hosts
  offline <- isTRUE(policy$outbound$offline)

  local <- if (is.null(hardware)) {
    list(device = "unknown", label = "not checked yet (run dragon_check())", model = NA_character_, four_bit = NA)
  } else {
    dev <- hardware$device %||% "cpu"
    label <- switch(dev,
      cuda = sprintf("%s, %s GB", hardware$device_name %||% "NVIDIA GPU", round(hardware$vram_gb %||% NA, 1)),
      mps = "Apple GPU",
      "CPU only")
    list(device = dev, label = label, model = hardware$tier$model %||% NA_character_,
         four_bit = isTRUE(hardware$tier$load_in_4bit))
  }

  services <- lapply(names(secret_catalog()), function(s) {
    st <- secret_status(s)
    list(service = s, title = secret_catalog()[[s]]$title, set = isTRUE(st$set), where = st$where)
  })
  names(services) <- names(secret_catalog())

  free <- lapply(names(provider_catalog()), function(p) {
    st <- provider_status(p, runs_dir)
    host <- outbound_host(provider_info(p)$base_url)
    list(provider = p, title = provider_info(p)$title, key = isTRUE(services[[p]]$set),
         opted_in = isTRUE(st$opted_in), daily_cap = st$daily_cap, used_today = st$used_today,
         host_allowed = is.null(allowed) || host_allowed(host, unlist(allowed)))
  })
  names(free) <- names(provider_catalog())
  usable_free <- names(Filter(function(f) f$key && f$opted_in && f$host_allowed &&
                                (is.null(f$daily_cap) || f$used_today < f$daily_cap), free))

  kaggle <- list(ready = kaggle_ready(),
                 host_allowed = is.null(allowed) || host_allowed("www.kaggle.com", unlist(allowed)))

  train_where <- if (identical(local$device, "cuda") || identical(local$device, "mps")) {
    "this computer"
  } else if (kaggle$ready && kaggle$host_allowed) {
    "Kaggle's free GPU (this computer has no GPU)"
  } else {
    "this computer, on the CPU (small models only)"
  }

  structure(list(local = local, services = services, free = free, usable_free = usable_free, kaggle = kaggle,
                 outbound = list(allowed_hosts = allowed, offline = offline), train_where = train_where),
            class = "dragon_where")
}

#' @export
print.dragon_where <- function(x, ...) {
  cli::cli_h2("This computer")
  if (is.na(x$local$model)) {
    cli::cli_text("{x$local$label}")
  } else {
    cli::cli_text("{x$local$label}. Answers with {.val {x$local$model}}{if (isTRUE(x$local$four_bit)) ' in 4-bit' else ''}.")
  }
  cli::cli_text("Training runs on {x$train_where}.")

  cli::cli_h2("Connected services")
  set <- Filter(function(s) s$set, x$services)
  if (length(set)) {
    cli::cli_bullets(stats::setNames(vapply(set, function(s) sprintf("%s (key in the %s)", s$title, s$where), ""),
                                     rep("v", length(set))))
  } else {
    cli::cli_text("None. Keys are added in the app's Settings page.")
  }

  cli::cli_h2("Free tiers")
  for (f in x$free) {
    state <- if (!f$key) "no key" else if (!f$opted_in) "key saved, not opted in" else if (!f$host_allowed)
      "opted in, but the policy blocks it" else if (!is.null(f$daily_cap))
      sprintf("in use when needed (%d of %d requests today)", f$used_today, f$daily_cap) else "in use when needed (no daily cap)"
    cli::cli_bullets(stats::setNames(sprintf("%s: %s", f$title, state), if (f$title %in% vapply(x$free[x$usable_free], `[[`, "", "title")) "v" else "*"))
  }

  cli::cli_h2("What may leave this computer")
  hosts <- x$outbound$allowed_hosts
  cli::cli_text(if (is.null(hosts)) "Any host, each call recorded." else if (!length(hosts)) "Nothing: no outside hosts are allowed." else
    paste0("Only ", paste(unlist(hosts), collapse = ", "), ", each call recorded."))
  if (isTRUE(x$outbound$offline)) cli::cli_text("Offline switch on: no model downloads.")
  invisible(x)
}
