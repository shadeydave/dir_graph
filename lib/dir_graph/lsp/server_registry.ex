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
    ".rs"  => {"rust-analyzer", []},
    ".php" => {"intelephense", ["--stdio"]},
    ".c"   => {"clangd", []},
    ".h"   => {"clangd", []},
    ".cpp" => {"clangd", []},
    ".cc"  => {"clangd", []},
    ".cxx" => {"clangd", []},
    ".hpp" => {"clangd", []}
  }

  # Install hints keyed by server executable name.
  # Shown in gap_report/0 so an LLM can propose the exact fix to the user.
  @install_hints %{
    "typescript-language-server" => %{
      description: "Symbol extraction and call hierarchy for JavaScript and TypeScript",
      extensions: [".js", ".jsx", ".ts", ".tsx"],
      install: "npm install -g typescript-language-server typescript",
      notes: "Requires Node.js. Both packages are needed — typescript-language-server delegates to the TypeScript compiler."
    },
    "pyright-langserver" => %{
      description: "Symbol extraction and call hierarchy for Python",
      extensions: [".py"],
      install: "npm install -g pyright",
      notes: "Requires Node.js. Alternatively: pip install pyright (installs the same binary via PyPI wrapper)."
    },
    "solargraph" => %{
      description: "Symbol extraction and call hierarchy for Ruby",
      extensions: [".rb"],
      install: "gem install solargraph",
      notes: "Requires Ruby gems. Run `solargraph download-core` after install for stdlib support."
    },
    "gopls" => %{
      description: "Symbol extraction and call hierarchy for Go",
      extensions: [".go"],
      install: "go install golang.org/x/tools/gopls@latest",
      notes: "Requires Go toolchain. The binary lands in $GOPATH/bin — ensure that is on PATH."
    },
    "rust-analyzer" => %{
      description: "Symbol extraction and call hierarchy for Rust",
      extensions: [".rs"],
      install: "rustup component add rust-analyzer",
      notes: "Requires rustup. If installed without rustup, download the binary from https://github.com/rust-lang/rust-analyzer/releases."
    },
    "intelephense" => %{
      description: "Symbol extraction and call hierarchy for PHP",
      extensions: [".php"],
      install: "npm install -g intelephense",
      notes: "Free tier covers all DirGraph features. A licence key unlocks additional IDE features but is not required here."
    },
    "clangd" => %{
      description: "Symbol extraction and call hierarchy for C and C++",
      extensions: [".c", ".h", ".cpp", ".cc", ".cxx", ".hpp"],
      install: "xcode-select --install",
      notes: "Already bundled with Xcode Command Line Tools on macOS. Alternatively: brew install llvm (gets a newer version)."
    }
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

  @doc """
  Returns a structured capability report split into `available` and `missing` servers.

  Each missing entry includes a human- and LLM-readable description of what the server
  provides, the exact install command, and any relevant notes. Intended for surfacing
  in `workspace_stats` so an LLM can detect gaps at session start and offer to install
  the dependency (e.g. via `spawn_process`) with user permission.

  Only reports servers that are configured (built-in defaults + user overrides).
  User-added servers not in `@install_hints` appear without install guidance.
  """
  @spec gap_report() :: %{available: [map()], missing: [map()]}
  def gap_report do
    load()
    |> Enum.group_by(fn {_ext, {cmd, _}} -> System.find_executable(cmd) != nil end)
    |> then(fn groups ->
      available =
        (groups[true] || [])
        |> Enum.group_by(fn {_ext, {cmd, _}} -> cmd end)
        |> Enum.map(fn {cmd, entries} ->
          exts = Enum.map(entries, fn {ext, _} -> ext end)
          %{server: cmd, extensions: exts}
        end)

      missing =
        (groups[false] || [])
        |> Enum.group_by(fn {_ext, {cmd, _}} -> cmd end)
        |> Enum.map(fn {cmd, entries} ->
          exts = Enum.map(entries, fn {ext, _} -> ext end)
          hint = Map.get(@install_hints, cmd, %{})

          %{
            server:      cmd,
            extensions:  exts,
            description: Map.get(hint, :description, "LSP server for #{Enum.join(exts, ", ")} files"),
            install:     Map.get(hint, :install, "See documentation for #{cmd}"),
            notes:       Map.get(hint, :notes)
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.into(%{})
        end)

      %{available: available, missing: missing}
    end)
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
