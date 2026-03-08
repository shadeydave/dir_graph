defmodule Mix.Tasks.Mcp.Server do
  use Mix.Task

  @shortdoc "Start the DirGraph MCP server (stdio JSON-RPC)"
  @moduledoc """
  Starts the DirGraph MCP server on stdio.

  Claude Code connects to this process via the MCP stdio transport.
  The server reads newline-delimited JSON-RPC from stdin and writes
  responses to stdout.

  ## Configuration

  Edit `.dir_graph/mcp_config.json` to control which tools are available
  and which file paths are accessible:

      {
        "allowed_tools": ["query_code_graph", "load_graph"],
        "allowed_paths": ["./lib", "./src"],
        "max_search_depth": 3
      }

  ## Claude Code setup

  Add to your project's `.claude/settings.json`:

      {
        "mcpServers": {
          "dir_graph": {
            "command": "mix",
            "args": ["mcp.server"],
            "cwd": "/absolute/path/to/your/project"
          }
        }
      }

  Or add globally in `~/.claude/settings.json` for use across projects.

  ## Pre-loading a graph

  For fast startup, pre-build and save the graph:

      mix run -e 'DirGraph.Indexer.index_directory(".") |> DirGraph.Indexer.save_graph("project.bin")'

  Then set `load_graph` as the first tool call in your session,
  or add auto-loading to your CLAUDE.md.
  """

  @requirements ["app.start"]

  def run(_args) do
    DirGraph.MCP.Server.start()
  end
end
