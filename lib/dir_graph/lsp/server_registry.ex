defmodule DirGraph.LSP.ServerRegistry do
  @moduledoc """
  Maps file extensions to LSP server commands.

  Ships with built-in defaults for common languages. Users can override or
  extend via `.dir_graph/lsp_servers.json` in the project root.

  Only returns a server if the executable is actually present on PATH,
  so callers don't need to handle "installed but wrong binary name" errors.

  ## Config format (.dir_graph/lsp_servers.json)

      {
        "servers": {
          ".ts": { "command": "typescript-language-server", "args": ["--stdio"] },
          ".py": { "command": "pylsp", "args": [] }
        }
      }

  Keys in the config file overlay (not replace) the built-in defaults,
  so you only need to list entries you want to change.
  """

  @config_path ".dir_graph/lsp_servers.json"

  # Built-in defaults. Keys are file extensions (including the dot).
  @defaults %{
    ".js"  => {"typescript-language-server", ["--stdio"]},
    ".jsx" => {"typescript-language-server", ["--stdio"]},
    ".ts"  => {"typescript-language-server", ["--stdio"]},
    ".tsx" => {"typescript-language-server", ["--stdio"]},
    ".py"  => {"pyright-langserver", ["--stdio"]},
    ".rb"  => {"solargraph", ["stdio"]},
    ".go"  => {"gopls", []},
    ".rs"  => {"rust-analyzer", []}
  }

  @doc """
  Returns `{:ok, {cmd, args}}` if a server is configured for `ext` and its
  executable is on PATH. Returns an error tuple otherwise.
  """
  @spec server_for(String.t()) ::
          {:ok, {String.t(), [String.t()]}}
          | {:error, :not_supported}
          | {:error, {:not_installed, String.t()}}
  def server_for(ext) do
    case Map.get(load(), ext) do
      nil ->
        {:error, :not_supported}

      {cmd, args} ->
        if System.find_executable(cmd) do
          {:ok, {cmd, args}}
        else
          {:error, {:not_installed, cmd}}
        end
    end
  end

  @doc "Returns all extensions for which a server is configured AND installed."
  @spec supported_extensions() :: [String.t()]
  def supported_extensions do
    load()
    |> Enum.filter(fn {_ext, {cmd, _}} -> System.find_executable(cmd) != nil end)
    |> Enum.map(fn {ext, _} -> ext end)
  end

  # ----------------------------------------------------------------

  defp load do
    case read_config() do
      %{"servers" => overrides} ->
        Enum.reduce(overrides, @defaults, fn {ext, config}, acc ->
          cmd = Map.get(config, "command")
          args = Map.get(config, "args", [])
          if cmd, do: Map.put(acc, ext, {cmd, args}), else: acc
        end)

      _ ->
        @defaults
    end
  end

  defp read_config do
    with {:ok, raw} <- File.read(@config_path),
         {:ok, decoded} <- Jason.decode(raw) do
      decoded
    else
      _ -> nil
    end
  end
end
