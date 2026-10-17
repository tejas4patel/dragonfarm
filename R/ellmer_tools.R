#' dragonfarm's tools for an ellmer chat or an MCP client
#'
#' Turns dragonfarm's tool contracts (search a document set, answer from it,
#' read documents, list sets and runs, check a run) into `ellmer` tools, so any
#' `ellmer` chat, with any model, can use your documents and runs. Every call
#' goes through the same checks as inside dragonfarm: arguments are checked
#' against the tool's contract, an `agent` is held to the current policy
#' (some calls are refused, some wait for a person), and every call is
#' recorded in the catalogue's event log.
#'
#' To offer them to Claude Desktop, Claude Code, or another MCP client, serve
#' them with the `mcptools` package, for example
#' `mcptools::mcp_server(tools = dragon_ellmer_tools())`.
#'
#' @param agent Name the caller as an agent in the policy (for example
#'   `"answer"`), so its calls are checked against what that agent may do.
#'   `NULL` (the default) means a person acting directly.
#' @param tools Which tools to include, by name. `NULL` includes all.
#' @return A list of `ellmer` tool definitions.
#' @export
#' @examples
#' if (requireNamespace("ellmer", quietly = TRUE)) {
#'   names(dragon_ellmer_tools())
#' }
#' \dontrun{
#' chat <- ellmer::chat_anthropic()
#' chat$register_tools(dragon_ellmer_tools())
#' chat$chat("What do my FDA guidances say about covariate adjustment?")
#' }
dragon_ellmer_tools <- function(agent = NULL, tools = NULL) {
  if (!requireNamespace("ellmer", quietly = TRUE)) {
    cli::cli_abort("{.fn dragon_ellmer_tools} needs the {.pkg ellmer} package: {.code install.packages(\"ellmer\")}.")
  }
  if (!is.null(agent)) check_string(agent, "agent")
  reg <- tool_registry()
  if (!is.null(tools)) {
    unknown <- setdiff(tools, names(reg))
    if (length(unknown)) cli::cli_abort("No tool called {.val {unknown}}. Available: {.val {names(reg)}}.")
    reg <- reg[tools]
  }
  defs <- lapply(reg, ellmer_tool_from_contract, agent = agent)
  names(defs) <- names(reg)
  defs
}

ellmer_tool_from_contract <- function(contract, agent = NULL) {
  props <- contract$input$properties
  required <- unlist(contract$input$required)
  arguments <- lapply(names(props), function(nm) {
    t <- ellmer::type_from_schema(as.character(jsonlite::toJSON(props[[nm]], auto_unbox = TRUE, null = "null")))
    S7::set_props(t, required = nm %in% required)
  })
  names(arguments) <- names(props)
  # A function whose arguments are the contract's properties: required ones
  # have no default, optional ones default to NULL (the contract's own
  # default then applies in tool_call()).
  formals_list <- lapply(names(props), function(nm) if (nm %in% required) quote(expr = ) else NULL)
  names(formals_list) <- names(props)
  name <- contract$name
  body <- rlang::expr({
    args <- as.list(environment())
    args <- args[!vapply(args, is.null, TRUE)]
    r <- tool_call(!!name, args, agent = !!agent)
    out <- if (isTRUE(r$ok)) r$result else list(error = r$error, code = r$code)
    # JSON text: what MCP clients and chat models read best.
    as.character(jsonlite::toJSON(out, auto_unbox = TRUE, null = "null"))
  })
  fun <- rlang::new_function(formals_list, body, env = asNamespace("dragonfarm"))
  ellmer::tool(
    fun, contract$description, arguments = arguments, name = name,
    annotations = ellmer::tool_annotations(
      title = contract$title,
      read_only_hint = identical(contract$side_effect, "read_only"),
      destructive_hint = identical(contract$side_effect, "irreversible"),
      open_world_hint = identical(contract$side_effect, "outbound")
    )
  )
}

#' Serve dragonfarm's tools to MCP clients
#'
#' Starts an MCP server (through the `mcptools` package) offering the tools
#' from [dragon_ellmer_tools()], so Claude Desktop, Claude Code, or another
#' MCP client can search and ask your document sets and check your runs.
#' Point the client at a command such as
#' `Rscript -e "dragonfarm::dragon_mcp_server()"`.
#'
#' The Python environment is located from a separate R process, because the
#' helpers that locate it would otherwise read the client's messages.
#'
#' @inheritParams dragon_ellmer_tools
#' @param runs_dir Where document sets and runs live.
#' @param ... Passed to `mcptools::mcp_server()`.
#' @return Does not return while the server runs.
#' @export
#' @examples
#' \dontrun{
#' # In the MCP client's configuration:
#' #   command: Rscript
#' #   args: ["-e", "dragonfarm::dragon_mcp_server()"]
#' dragon_mcp_server()
#' }
dragon_mcp_server <- function(agent = NULL, tools = NULL, runs_dir = dragon_runs_dir(), ...) {
  if (!requireNamespace("mcptools", quietly = TRUE)) {
    cli::cli_abort("{.fn dragon_mcp_server} needs the {.pkg mcptools} package: {.code install.packages(\"mcptools\")}.")
  }
  options(dragonfarm.runs_dir = runs_dir, dragonfarm.python_in_child = TRUE)
  mcptools::mcp_server(tools = dragon_ellmer_tools(agent = agent, tools = tools), ...)
}
