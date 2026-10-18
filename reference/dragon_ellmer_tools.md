# dragonfarm's tools for an ellmer chat or an MCP client

Turns dragonfarm's tool contracts (search a document set, answer from
it, read documents, list sets and runs, check a run) into `ellmer`
tools, so any `ellmer` chat, with any model, can use your documents and
runs. Every call goes through the same checks as inside dragonfarm:
arguments are checked against the tool's contract, an `agent` is held to
the current policy (some calls are refused, some wait for a person), and
every call is recorded in the catalogue's event log.

## Usage

``` r
dragon_ellmer_tools(agent = NULL, tools = NULL)
```

## Arguments

- agent:

  Name the caller as an agent in the policy (for example `"answer"`), so
  its calls are checked against what that agent may do. `NULL` (the
  default) means a person acting directly.

- tools:

  Which tools to include, by name. `NULL` includes all.

## Value

A list of `ellmer` tool definitions.

## Details

To offer them to Claude Desktop, Claude Code, or another MCP client,
serve them with the `mcptools` package, for example
`mcptools::mcp_server(tools = dragon_ellmer_tools())`.

## Examples

``` r
if (requireNamespace("ellmer", quietly = TRUE)) {
  names(dragon_ellmer_tools())
}
#>  [1] "answer_question"          "cancel_run"              
#>  [3] "evaluate_run"             "list_document_sets"      
#>  [5] "list_runs"                "promote_model"           
#>  [7] "read_documents"           "run_status"              
#>  [9] "search_documents"         "train_model"             
#> [11] "write_practice_questions"
if (FALSE) { # \dontrun{
chat <- ellmer::chat_anthropic()
chat$register_tools(dragon_ellmer_tools())
chat$chat("What do my FDA guidances say about covariate adjustment?")
} # }
```
