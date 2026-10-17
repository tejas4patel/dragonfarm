# Serve dragonfarm's tools to MCP clients

Starts an MCP server (through the `mcptools` package) offering the tools
from
[`dragon_ellmer_tools()`](https://dragonfarm.dev/reference/dragon_ellmer_tools.md),
so Claude Desktop, Claude Code, or another MCP client can search and ask
your document sets and check your runs. Point the client at a command
such as `Rscript -e "dragonfarm::dragon_mcp_server()"`.

## Usage

``` r
dragon_mcp_server(
  agent = NULL,
  tools = NULL,
  runs_dir = dragon_runs_dir(),
  ...
)
```

## Arguments

- agent:

  Name the caller as an agent in the policy (for example `"answer"`), so
  its calls are checked against what that agent may do. `NULL` (the
  default) means a person acting directly.

- tools:

  Which tools to include, by name. `NULL` includes all.

- runs_dir:

  Where document sets and runs live.

- ...:

  Passed to
  [`mcptools::mcp_server()`](https://posit-dev.github.io/mcptools/reference/server.html).

## Value

Does not return while the server runs.

## Details

The Python environment is located from a separate R process, because the
helpers that locate it would otherwise read the client's messages.

## Examples

``` r
if (FALSE) { # \dontrun{
# In the MCP client's configuration:
#   command: Rscript
#   args: ["-e", "dragonfarm::dragon_mcp_server()"]
dragon_mcp_server()
} # }
```
