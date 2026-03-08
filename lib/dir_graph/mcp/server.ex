defmodule DirGraph.MCP.Server do
  @moduledoc """
  MCP stdio transport loop.

  Reads newline-delimited JSON-RPC 2.0 messages from stdin, reloads the
  allowlist from disk on every message (so session plan changes take effect
  immediately), dispatches to Handler, and writes responses to stdout.
  """

  alias DirGraph.MCP.{Allowlist, Handler}

  def start do
    initial = Allowlist.load()
    log("DirGraph MCP server started.")
    log("Static tools: #{inspect(initial.static_tools)}")
    log("Allowed paths: #{inspect(initial.static_paths)}")
    loop()
  end

  defp loop do
    case IO.gets("") do
      :eof ->
        log("Client disconnected (EOF). Shutting down.")

      {:error, reason} ->
        log("IO error: #{inspect(reason)}. Shutting down.")

      line ->
        line = String.trim(line)

        if line != "" do
          # Reload allowlist on every message — hot-picks up session plan changes
          allowlist = Allowlist.load()

          case Jason.decode(line) do
            {:ok, msg} ->
              case Handler.handle(msg, allowlist) do
                nil -> :ok
                response -> IO.puts(Jason.encode!(response))
              end

            {:error, _} ->
              log("Malformed JSON, skipping.")
          end
        end

        loop()
    end
  end

  defp log(msg), do: IO.puts(:stderr, "[dir_graph mcp] #{msg}")
end
