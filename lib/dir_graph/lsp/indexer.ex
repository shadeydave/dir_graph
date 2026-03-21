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

  require Logger

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
        Logger.warning("LSP server '#{cmd}' not found — skipping #{file_path}")
        {graph, []}

      {:ok, {cmd, args}} ->
        root = find_root(file_path)

        case Client.start(cmd, args, root) do
          {:ok, client} ->
            {graph, refs, client} = index_one(client, file_path, graph)
            Client.stop(client)
            {graph, refs}

          {:error, reason} ->
            Logger.warning("Failed to start '#{cmd}' for #{file_path}: #{inspect(reason)}")
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
          Logger.warning("LSP server '#{cmd}' not found — skipping #{ext} files")
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
              Logger.warning("Failed to start LSP server '#{cmd}': #{inspect(reason)}")
              {g, all_refs}
          end
      end
    end)
  end

  # ----------------------------------------------------------------
  # Internal
  # ----------------------------------------------------------------

  # LSP SymbolKind integers for callable symbols (Method, Constructor, Function).
  # These are the only kinds for which prepareCallHierarchy makes sense.
  @callable_kinds [6, 9, 12]

  # Returns {graph, refs, updated_client} so client state threads through batches.
  defp index_one(client, file_path, graph) do
    client = Client.open_document(client, file_path)

    case Client.fetch_symbols(client, file_path) do
      {:ok, symbols, client} ->
        file_node_id = "File:#{file_path}"
        file_name = Path.basename(file_path)

        graph = CG.add_node(graph, file_node_id, "File", file_name, %{path: file_path})
        {graph, _symbol_refs} = SymbolMapper.symbols_to_graph(symbols, file_path, file_node_id, graph)

        # Call hierarchy pass: outgoing CALLS edges + onion-skin metadata.
        # The file is still open, so prepareCallHierarchy requests are valid.
        positions = callable_positions(symbols, file_path)
        {graph, client} = build_calls_edges(client, file_path, positions, graph)

        client = Client.close_document(client, file_path)

        # documentSymbol gives structure but not import paths — extract separately.
        import_refs = ImportExtractor.extract(file_path)

        {graph, import_refs, client}

      {:error, reason} ->
        Logger.warning("documentSymbol failed for #{file_path}: #{inspect(reason)}")
        Client.close_document(client, file_path)
        {graph, [], client}
    end
  end

  # Recursively collects {node_id, lsp_line, lsp_char} for every callable symbol
  # in the DocumentSymbol tree. Uses the same ID format as SymbolMapper so the
  # node is guaranteed to exist in the graph when we add CALLS edges to it.
  defp callable_positions(symbols, file_path) do
    Enum.flat_map(symbols, &collect_positions(&1, file_path))
  end

  defp collect_positions(symbol, file_path) do
    kind = Map.get(symbol, "kind", 0)
    children = Map.get(symbol, "children", [])
    child_positions = Enum.flat_map(children, &collect_positions(&1, file_path))

    if kind in @callable_kinds do
      name     = Map.get(symbol, "name", "unknown")
      lsp_line = get_in(symbol, ["selectionRange", "start", "line"]) ||
                 get_in(symbol, ["range", "start", "line"]) || 0
      lsp_char = get_in(symbol, ["selectionRange", "start", "character"]) || 0
      dir_line = lsp_line + 1
      node_id  = "Function:#{name}:L#{dir_line}:#{file_path}"

      [{node_id, lsp_line, lsp_char} | child_positions]
    else
      child_positions
    end
  end

  # For each callable position, request outgoing calls and add CALLS edges.
  # If the target node is already in the graph (indexed from another file),
  # link directly. Otherwise create a lightweight Call placeholder so the
  # edge still exists for `affected_by` and the onion-skin metadata.
  defp build_calls_edges(client, file_path, positions, graph) do
    Enum.reduce(positions, {graph, client}, fn {caller_id, lsp_line, lsp_char}, {g, c} ->
      case Client.outgoing_calls(c, file_path, lsp_line, lsp_char) do
        {:ok, calls, c} ->
          g =
            Enum.reduce(calls, g, fn %{name: name, uri: target_uri, line: target_line}, g_acc ->
              target_file = uri_to_path(target_uri)
              preferred_id = "Function:#{name}:L#{target_line}:#{target_file}"

              {g_acc, target_id} =
                if CG.get_label(g_acc, preferred_id) do
                  {g_acc, preferred_id}
                else
                  call_id = "Call:#{name}:L#{target_line}:#{target_file}"
                  {CG.add_node(g_acc, call_id, "Call", name, %{line: target_line, file: target_file}), call_id}
                end

              CG.add_edge(g_acc, caller_id, target_id, "CALLS")
            end)

          {g, c}

        {:error, reason} ->
          Logger.warning("call hierarchy failed for #{file_path} at position #{lsp_line}:#{lsp_char}: #{inspect(reason)}")
          {g, c}
      end
    end)
  end

  defp uri_to_path("file://" <> path), do: path
  defp uri_to_path(uri), do: uri

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
