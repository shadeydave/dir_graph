defmodule DirGraph.LSP.Indexer do
  @moduledoc """
  Indexes non-Elixir source files using an LSP server.

  ## Single file vs batch

  LSP servers are slow to initialize (100–500ms) but fast once running.
  Starting a new server per file would make directory indexing unusable.

  - `index_file/2` — starts and stops a server for one file. Fine for
    on-demand MCP queries and single-file CLI calls.

  - `index_files/2` — groups a list of files by extension, starts one
    server per language, indexes all files of that language, then stops
    the server. Used by `DirGraph.Indexer.index_directory/1`.

  ## Cross-file references

  `textDocument/documentSymbol` only returns the symbol tree for one file;
  it does not surface import relationships. Cross-file IMPORTS edges for
  LSP-backed languages are left to the caller (the parent Indexer) which
  can apply its own lightweight resolution pass.
  """

  alias DirGraph.LSP.{Client, ServerRegistry, SymbolMapper, ImportExtractor}
  alias DirGraph.Graph, as: CG

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  @doc """
  Indexes a single file using an LSP server. Starts and stops the server
  around this one call, so latency is higher than batch indexing.
  Returns `{graph, refs}` matching the shape of `DirGraph.Indexer.index_file/2`.
  """
  def index_file(file_path, graph \\ CG.new()) do
    ext = Path.extname(file_path)

    case ServerRegistry.server_for(ext) do
      {:error, :not_supported} ->
        {graph, []}

      {:error, {:not_installed, cmd}} ->
        IO.puts("Warning: LSP server '#{cmd}' not found — skipping #{file_path}")
        {graph, []}

      {:ok, {cmd, args}} ->
        root = find_root(file_path)

        case Client.start(cmd, args, root) do
          {:ok, client} ->
            {graph, refs, client} = index_one(client, file_path, graph)
            Client.stop(client)
            {graph, refs}

          {:error, reason} ->
            IO.puts("Warning: failed to start '#{cmd}' for #{file_path}: #{inspect(reason)}")
            {graph, []}
        end
    end
  end

  @doc """
  Indexes a single file using an already-running client. Returns
  `{graph, refs, updated_client}`. Use this when the caller manages the
  client lifecycle (e.g. `DirGraph.Server` for persistent connections).
  """
  def index_file_with_client(client, file_path, graph) do
    index_one(client, file_path, graph)
  end

  @doc """
  Indexes a list of files efficiently: groups by extension, starts one LSP
  server per language, indexes all files for that language, then stops.

  Returns `{graph, refs}` with all files merged into the graph.
  """
  def index_files(file_paths, graph \\ CG.new()) do
    file_paths
    |> Enum.group_by(&Path.extname/1)
    |> Enum.reduce({graph, []}, fn {ext, files}, {g, all_refs} ->
      case ServerRegistry.server_for(ext) do
        {:error, :not_supported} ->
          {g, all_refs}

        {:error, {:not_installed, cmd}} ->
          IO.puts("Warning: LSP server '#{cmd}' not found — skipping #{ext} files")
          {g, all_refs}

        {:ok, {cmd, args}} ->
          root = files |> hd() |> find_root()

          case Client.start(cmd, args, root) do
            {:ok, client} ->
              {g2, refs2, client} =
                Enum.reduce(files, {g, all_refs, client}, fn path, {g_acc, r_acc, c} ->
                  {g_new, new_refs, c_new} = index_one(c, path, g_acc)
                  {g_new, r_acc ++ new_refs, c_new}
                end)

              Client.stop(client)
              {g2, refs2}

            {:error, reason} ->
              IO.puts("Warning: failed to start LSP server '#{cmd}': #{inspect(reason)}")
              {g, all_refs}
          end
      end
    end)
  end

  # ----------------------------------------------------------------
  # Internal
  # ----------------------------------------------------------------

  # Returns {graph, refs, updated_client} so client state threads through batches.
  defp index_one(client, file_path, graph) do
    case Client.document_symbols(client, file_path) do
      {:ok, symbols, client} ->
        file_node_id = "File:#{file_path}"
        file_name = Path.basename(file_path)

        graph = CG.add_node(graph, file_node_id, "File", file_name, %{path: file_path})
        {graph, _symbol_refs} = SymbolMapper.symbols_to_graph(symbols, file_path, file_node_id, graph)

        # documentSymbol gives us structure but not imports — extract those separately
        import_refs = ImportExtractor.extract(file_path)

        {graph, import_refs, client}

      {:error, reason} ->
        IO.puts("Warning: documentSymbol failed for #{file_path}: #{inspect(reason)}")
        {graph, [], client}
    end
  end

  # Walk up the directory tree looking for a project root marker.
  # Falls back to the file's own directory if none is found.
  @root_markers ~w(package.json mix.exs Cargo.toml go.mod pyproject.toml .git)

  defp find_root(file_path) do
    dir = file_path |> Path.expand() |> Path.dirname()
    walk_to_root(dir)
  end

  defp walk_to_root(dir) do
    if Enum.any?(@root_markers, &File.exists?(Path.join(dir, &1))) do
      dir
    else
      parent = Path.dirname(dir)
      if parent == dir, do: dir, else: walk_to_root(parent)
    end
  end
end
