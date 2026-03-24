defmodule DirGraph.Server do
  @moduledoc """
  A GenServer that holds the DirGraph CPG in memory for fast repeated queries.

  ## Usage

      # Index a file into the running server
      DirGraph.Server.index_file("lib/auth.ex")

      # Search for a concept and get a compact LLM-ready slice
      {:ok, payload} = DirGraph.Server.extract_slice("login", depth: 2)

      # Load a pre-compiled graph from disk (fastest startup)
      DirGraph.Server.load("project_graph.bin")
  """
  use GenServer

  alias DirGraph.{Indexer, Analyzer, RAG, ContentStore}
  alias DirGraph.LSP.Indexer, as: LSPIndexer
  alias DirGraph.LSP.{ServerRegistry, Client}
  alias DirGraph.Graph, as: CG

  # ----------------------------------------------------------------
  # Client API
  # ----------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{graph: CG.new(), lsp_clients: %{}, manifest: %{}, project_name: nil}, name: __MODULE__)
  end

  @doc "Index a single file, merging it into the in-memory graph. Blocks until complete."
  def index_file(file_path) do
    GenServer.call(__MODULE__, {:index_file, file_path}, :infinity)
  end

  @doc "Index an entire directory, replacing the current graph."
  def index_directory(dir_path) do
    GenServer.call(__MODULE__, {:index_directory, dir_path}, :infinity)
  end

  @doc "Load a pre-compiled graph binary from disk, replacing the current graph."
  def load(bin_path) do
    GenServer.call(__MODULE__, {:load, bin_path}, :infinity)
  end

  @doc """
  Extracts a semantic slice around `search_term` up to `depth` hops.
  Returns `{:ok, payload}` or `{:error, :not_found}`.

  Options:
  - `depth` — BFS hops (1–3, default 2)
  - `include_code` — embed source lines per node (default false)
  """
  def extract_slice(search_term, opts \\ []) do
    GenServer.call(__MODULE__, {:extract_slice, search_term, opts})
  end

  @doc """
  Finds all nodes that could break if `search_term` changes (inbound graph walk).
  Returns `{:ok, payload}` or `{:error, :not_found}`.
  """
  def affected_by(search_term, opts \\ []) do
    GenServer.call(__MODULE__, {:affected_by, search_term, opts})
  end

  @doc "Finds test nodes that exercise `search_term` via inbound BFS filtered to test/spec paths."
  def find_tests(search_term, opts \\ []) do
    GenServer.call(__MODULE__, {:find_tests, search_term, opts})
  end

  @doc "Returns counts and topology stats for the current graph."
  def workspace_stats do
    GenServer.call(__MODULE__, :workspace_stats)
  end

  @doc """
  Applies a surgical mutation payload to a source file using the current graph for
  node lookup. Verifies Elixir syntax before writing. Re-indexes the file on success
  so the graph stays in sync.
  Returns `{:ok, new_source}` or `{:error, reason}`.
  """
  def apply_diff(file_path, diff_payload) do
    GenServer.call(__MODULE__, {:apply_diff, file_path, diff_payload}, :infinity)
  end

  # Content node API — all calls are synchronous for data consistency.

  @doc "Create a content node, add it to the graph, and return it."
  def add_content_node(attrs), do: GenServer.call(__MODULE__, {:content_add, attrs})

  @doc "Update an existing content node's fields and/or IMPLEMENTS links."
  def update_content_node(id, attrs), do: GenServer.call(__MODULE__, {:content_update, id, attrs})

  @doc "Delete a content node and remove it from the graph."
  def delete_content_node(id), do: GenServer.call(__MODULE__, {:content_delete, id})

  @doc "Return all code nodes linked to a content node via IMPLEMENTS edges."
  def find_implementations(id), do: GenServer.call(__MODULE__, {:content_find_impl, id})

  @doc "Return all content nodes, optionally filtered by type."
  def list_content_nodes(type \\ nil), do: GenServer.call(__MODULE__, {:content_list, type})

  @doc """
  Semantic search: embed `query`, find top-K similar nodes by cosine similarity,
  then BFS from each seed to build a merged context slice.
  Returns `{:ok, payload}` or `{:error, reason}`.
  """
  def semantic_search(query, opts \\ []) do
    GenServer.call(__MODULE__, {:semantic_search, query, opts}, 60_000)
  end

  @doc "Returns the full in-memory graph (for inspection or serialization)."
  def get_graph do
    GenServer.call(__MODULE__, :get_graph)
  end

  @doc """
  Serializes the current graph to JSON files under ~/sites/diffs/{project}/ and
  opens the viewer in the system browser. Creates full_ast.json and (if missing)
  an empty diff_ledger.json. Idempotent — re-exporting overwrites full_ast.json
  but never truncates an existing ledger.
  """
  def export_viewer_data(project) do
    GenServer.call(__MODULE__, {:export_viewer_data, project}, :infinity)
  end

  @doc "Remove all graph nodes belonging to `file_path` (called by Watcher on file deletion)."
  def remove_file(file_path) do
    GenServer.call(__MODULE__, {:remove_file, file_path})
  end

  @doc """
  Sync the graph against `dir_path`: re-index new/modified files, purge deleted ones.
  Uses the manifest embedded in the last `load_graph` or `save_graph` call to detect
  the delta — only changed files are touched.
  Returns `{:ok, %{new: n, modified: n, deleted: n}}`.
  """
  def sync(dir_path) do
    GenServer.call(__MODULE__, {:sync, dir_path}, :infinity)
  end

  # ----------------------------------------------------------------
  # Server callbacks
  # ----------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:index_file, file_path}, _from, state) do
    ext = Path.extname(file_path)

    # Purge stale nodes for this file before re-indexing so changed line
    # numbers and removed functions don't leave ghost nodes in the graph.
    base_graph = Indexer.purge_file(state.graph, file_path)

    {new_graph, refs, new_clients} =
      if ext in ~w(.ex .exs) do
        {g, r} = Indexer.index_file(file_path, base_graph)
        {g, r, state.lsp_clients}
      else
        case ServerRegistry.server_for(ext) do
          {:ok, {cmd, args}} ->
            {client, clients} = get_or_start_client(state.lsp_clients, cmd, args, file_path)
            {g, r, client} = LSPIndexer.index_file_with_client(client, file_path, base_graph)
            {g, r, Map.put(clients, cmd, client)}

          {:error, _} ->
            {g, r} = Indexer.index_file(file_path, base_graph)
            {g, r, state.lsp_clients}
        end
      end

    resolved = Indexer.resolve_cross_file_refs(new_graph, refs)

    # Background: embed newly indexed nodes for semantic search.
    RAG.index_file(resolved, file_path)

    # Background: persist new/updated nodes + their edges to Neo4j.
    if state.project_name do
      project = state.project_name
      file_nodes = file_node_ids(resolved, file_path)
      Task.start(fn -> sync_file_to_neo4j(project, resolved, file_path, file_nodes) end)
    end

    {:reply, :ok, %{state | graph: resolved, lsp_clients: new_clients}}
  end

  @impl true
  def handle_call({:index_directory, dir_path}, _from, state) do
    graph    = Indexer.index_directory(dir_path)
    # Restore content nodes (they live in JSON, not source files).
    graph    = reload_content_nodes(graph)
    manifest = DirGraph.Manifest.from_graph(graph)

    project  = Path.basename(Path.expand(dir_path))
    RAG.set_project(project)
    RAG.index_graph(graph)

    # Background: full graph sync to Neo4j.
    Task.start(fn -> DirGraph.Neo4j.persist_graph(project, graph) end)

    {:reply, :ok, %{state | graph: graph, manifest: manifest, project_name: project}}
  end

  @impl true
  def handle_call({:load, bin_path}, _from, state) do
    {graph, manifest} = Indexer.load_graph(bin_path)
    # Reload content nodes in case the .bin predates any content nodes that
    # have been added since, or was built without them.
    graph = reload_content_nodes(graph)

    # Derive project name from the .bin filename (e.g. "dir_graph.bin" → "dir_graph").
    project = bin_path |> Path.basename() |> Path.rootname()
    RAG.set_project(project)
    RAG.index_graph(graph)

    # Background: sync the loaded graph to Neo4j for cross-project persistence.
    Task.start(fn -> DirGraph.Neo4j.persist_graph(project, graph) end)

    {:reply, :ok, %{state | graph: graph, manifest: manifest, project_name: project}}
  end

  @impl true
  def handle_call({:remove_file, file_path}, _from, state) do
    # Collect node IDs before purging so we can clean the vector store.
    removed_ids =
      Graph.vertices(state.graph)
      |> Enum.filter(fn vid ->
        case CG.get_label(state.graph, vid) do
          %{file: ^file_path} -> true
          %{path: ^file_path} -> true
          _ -> false
        end
      end)

    graph    = Indexer.purge_file(state.graph, file_path)
    manifest = Map.delete(state.manifest, file_path)

    RAG.remove_file_nodes(removed_ids)

    if state.project_name do
      project = state.project_name
      Task.start(fn -> DirGraph.Neo4j.purge_file_nodes(project, file_path) end)
    end

    {:reply, :ok, %{state | graph: graph, manifest: manifest}}
  end

  @impl true
  def handle_call({:sync, dir_path}, _from, state) do
    current_files = Indexer.collect_files(dir_path)
    delta = DirGraph.Manifest.diff(state.manifest, current_files)

    # Purge deleted files
    graph =
      Enum.reduce(delta.deleted, state.graph, fn path, g ->
        Indexer.purge_file(g, path)
      end)

    # Purge modified files before re-indexing (stale cleanup)
    graph =
      Enum.reduce(delta.modified, graph, fn path, g ->
        Indexer.purge_file(g, path)
      end)

    # Index new + modified files
    graph = Indexer.index_file_list(delta.new ++ delta.modified, graph)

    new_manifest = DirGraph.Manifest.from_graph(graph)
    stats = %{new: length(delta.new), modified: length(delta.modified), deleted: length(delta.deleted)}

    {:reply, {:ok, stats}, %{state | graph: graph, manifest: new_manifest}}
  end

  @impl true
  def handle_call({:extract_slice, search_term, opts}, _from, state) do
    depth         = Keyword.get(opts, :depth, 2)
    include_code  = Keyword.get(opts, :include_code, false)
    node_type     = Keyword.get(opts, :node_type, nil)
    include_types = if node_type, do: List.wrap(node_type), else: :all

    case Analyzer.find_node(state.graph, search_term) do
      nil ->
        {:reply, {:error, :not_found}, state}

      vertex_id ->
        subgraph = Analyzer.extract_slice(state.graph, vertex_id, depth)
        payload  = Analyzer.format_for_llm(subgraph, include_code: include_code, include_types: include_types, full_graph: state.graph)
        {:reply, {:ok, payload}, state}
    end
  end

  @impl true
  def handle_call({:affected_by, search_term, opts}, _from, state) do
    depth        = Keyword.get(opts, :depth, 2)
    include_code = Keyword.get(opts, :include_code, false)

    case Analyzer.find_node(state.graph, search_term) do
      nil ->
        {:reply, {:error, :not_found}, state}

      vertex_id ->
        subgraph = Analyzer.affected_by(state.graph, vertex_id, depth)
        payload  = Analyzer.format_for_llm(subgraph, include_code: include_code, full_graph: state.graph)
        {:reply, {:ok, payload}, state}
    end
  end

  @impl true
  def handle_call({:find_tests, search_term, opts}, _from, state) do
    {:reply, Analyzer.find_tests(state.graph, search_term, opts), state}
  end

  @impl true
  def handle_call({:apply_diff, file_path, diff_payload}, _from, state) do
    case DirGraph.Weaver.apply_diff(file_path, state.graph, diff_payload) do
      {:ok, new_source} ->
        # Re-index the modified file to keep the graph in sync.
        {new_graph, _refs} = Indexer.index_file(file_path, state.graph)
        {:reply, {:ok, new_source}, %{state | graph: new_graph}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:workspace_stats, _from, state) do
    graph    = state.graph
    vertices = Graph.vertices(graph)
    edges    = Graph.edges(graph)

    nodes_by_type =
      vertices
      |> Enum.group_by(fn vid ->
        case CG.get_label(graph, vid) do
          %{type: t} -> t
          _ -> "unknown"
        end
      end)
      |> Enum.map(fn {type, vids} -> {type, length(vids)} end)
      |> Enum.sort_by(fn {_, count} -> count end, :desc)
      |> Map.new()

    top_connected =
      vertices
      |> Enum.map(fn vid ->
        degree = length(Graph.out_neighbors(graph, vid)) + length(Graph.in_neighbors(graph, vid))
        name   = case CG.get_label(graph, vid) do
          %{name: n} -> n
          _ -> vid
        end
        %{id: vid, name: name, degree: degree}
      end)
      |> Enum.sort_by(& &1.degree, :desc)
      |> Enum.take(10)

    calls_edges     = Enum.count(edges, fn e -> e.label == "CALLS" end)
    capability_gaps = DirGraph.LSP.ServerRegistry.gap_report()

    stats = %{
      total_nodes:          length(vertices),
      total_edges:          length(edges),
      calls_edges:          calls_edges,
      files_indexed:        Map.get(nodes_by_type, "File", 0),
      nodes_by_type:        nodes_by_type,
      top_connected:        top_connected,
      watched_dirs:         DirGraph.Watcher.watched_dirs(),
      embeddings_ready:     DirGraph.RAG.size(),
      embeddings_available: DirGraph.Embeddings.available?(),
      capability_gaps:      capability_gaps
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:semantic_search, query, opts}, _from, state) do
    top_k        = Keyword.get(opts, :top_k, 5)
    depth        = Keyword.get(opts, :depth, 2)
    include_code = Keyword.get(opts, :include_code, false)

    result =
      case RAG.search(query, top_k) do
        {:error, reason} ->
          {:error, reason}

        {:ok, []} ->
          {:error, :no_embeddings}

        {:ok, seeds} ->
          # BFS from each seed node, then union all vertices into one slice.
          all_vertex_ids =
            seeds
            |> Enum.flat_map(fn {node_id, _score} ->
              subgraph = Analyzer.extract_slice(state.graph, node_id, depth)
              Graph.vertices(subgraph)
            end)
            |> Enum.uniq()

          subgraph = Graph.subgraph(state.graph, all_vertex_ids)
          payload  = Analyzer.format_for_llm(subgraph, include_code: include_code, full_graph: state.graph)

          # Annotate with which nodes were the semantic entry points.
          matches =
            Enum.map(seeds, fn {node_id, score} ->
              name = case CG.get_label(state.graph, node_id) do
                %{name: n} -> n
                _ -> node_id
              end
              %{node_id: node_id, name: name, score: Float.round(score, 4)}
            end)

          {:ok, Map.put(payload, :semantic_matches, matches)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_graph, _from, state) do
    {:reply, state.graph, state}
  end

  # ----------------------------------------------------------------
  # Content node handlers
  # ----------------------------------------------------------------

  @impl true
  def handle_call({:content_add, attrs}, _from, state) do
    type    = Map.get(attrs, "type", "Domain")
    name    = Map.get(attrs, "name", "")
    content = Map.get(attrs, "content", "")
    links   = Map.get(attrs, "implements", [])

    cond do
      name == "" ->
        {:reply, {:error, "name is required"}, state}

      type not in ContentStore.valid_types() ->
        {:reply, {:error, "Invalid type '#{type}'. Valid types: #{Enum.join(ContentStore.valid_types(), ", ")}"}, state}

      true ->
        id = ContentStore.make_id(type, name)
        node = %{
          "id"         => id,
          "type"       => type,
          "name"       => name,
          "content"    => content,
          "implements" => links,
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        case ContentStore.put(node) do
          {:ok, saved} ->
            graph = add_content_to_graph(state.graph, saved)
            RAG.index_node(id, "#{type} #{name}: #{content}")
            {:reply, {:ok, saved}, %{state | graph: graph}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:content_update, id, attrs}, _from, state) do
    case ContentStore.get(id) do
      nil ->
        {:reply, {:error, "Content node '#{id}' not found."}, state}

      existing ->
        # Merge scalar updates.
        updated =
          existing
          |> maybe_put("name",    Map.get(attrs, "name"))
          |> maybe_put("content", Map.get(attrs, "content"))
          |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

        # Merge link changes.
        links = Map.get(updated, "implements", [])
        links = links ++ Map.get(attrs, "add_implements", [])
        links = links -- Map.get(attrs, "remove_implements", [])
        updated = Map.put(updated, "implements", Enum.uniq(links))

        case ContentStore.put(updated) do
          {:ok, saved} ->
            # Remove old vertex (libgraph add_node is a no-op on existing IDs,
            # so we delete first to pick up the new label).
            graph = Graph.delete_vertex(state.graph, id)
            graph = add_content_to_graph(graph, saved)
            RAG.index_node(id, "#{saved["type"]} #{saved["name"]}: #{saved["content"]}")
            {:reply, {:ok, saved}, %{state | graph: graph}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:content_delete, id}, _from, state) do
    case ContentStore.delete(id) do
      :ok ->
        graph = Graph.delete_vertex(state.graph, id)
        RAG.remove_node(id)
        {:reply, :ok, %{state | graph: graph}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:content_find_impl, id}, _from, state) do
    node = ContentStore.get(id)

    if is_nil(node) do
      {:reply, {:error, "Content node '#{id}' not found."}, state}
    else
      impl_ids = Map.get(node, "implements", [])

      implementations =
        Enum.flat_map(impl_ids, fn code_id ->
          case CG.get_label(state.graph, code_id) do
            nil   -> [%{id: code_id, status: "not_in_graph"}]
            label -> [label]
          end
        end)

      {:reply, {:ok, %{content_node: node, implementations: implementations}}, state}
    end
  end

  @impl true
  def handle_call({:content_list, type_filter}, _from, state) do
    nodes =
      ContentStore.all()
      |> then(fn list ->
        if type_filter do
          Enum.filter(list, fn n -> n["type"] == type_filter end)
        else
          list
        end
      end)

    {:reply, {:ok, nodes}, state}
  end

  @impl true
  # Node types for the top-level architectural view in the viewer.
  # Function/Call nodes are too granular for planning — they're available
  # via the analysis tools but would make the canvas unworkable.
  # Content nodes (BusinessRule etc.) are always included.
  @viewer_node_types ~w(File Module Class BusinessRule Copy Contract Domain)

  def handle_call({:export_viewer_data, project}, _from, state) do
    all_nodes = CG.all_nodes(state.graph)

    nodes =
      all_nodes
      |> Enum.filter(fn n -> to_string(n[:type] || "") in @viewer_node_types end)
      |> Enum.map(fn n ->
        %{
          "id"   => to_string(n[:id]   || ""),
          "type" => to_string(n[:type] || ""),
          "name" => to_string(n[:name] || ""),
          "file" => to_string(n[:file] || ""),
          "line" => n[:line] || 0
        }
      end)

    node_ids = MapSet.new(nodes, & &1["id"])

    edges =
      Graph.edges(state.graph)
      |> Enum.filter(fn e ->
        MapSet.member?(node_ids, e.v1) and MapSet.member?(node_ids, e.v2)
      end)
      |> Enum.map(fn e ->
        %{"source" => e.v1, "target" => e.v2, "rel" => to_string(e.label)}
      end)

    ast = %{
      "project"     => project,
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "node_count"  => length(nodes),
      "edge_count"  => length(edges),
      "nodes"       => nodes,
      "edges"       => edges
    }

    diffs_dir   = Path.expand("~/sites/diffs/#{project}")
    ast_path    = Path.join(diffs_dir, "full_ast.json")
    ledger_path = Path.join(diffs_dir, "diff_ledger.json")

    File.mkdir_p!(diffs_dir)
    File.write!(ast_path, Jason.encode!(ast, pretty: true))

    unless File.exists?(ledger_path) do
      ledger = %{"project" => project, "base_ast" => "full_ast.json", "diffs" => []}
      File.write!(ledger_path, Jason.encode!(ledger, pretty: true))
    end

    System.cmd("open", ["http://localhost:5173/?project=#{project}"])

    result = %{
      status:  "ok",
      path:    diffs_dir,
      nodes:   length(nodes),
      edges:   length(edges),
      message: "Exported #{length(nodes)} nodes, #{length(edges)} edges. Opening viewer at http://localhost:5173/?project=#{project}"
    }

    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.lsp_clients, fn {_cmd, client} ->
      try do
        Client.stop(client)
      catch
        _, _ -> :ok
      end
    end)
  end

  # ----------------------------------------------------------------
  # LSP client lifecycle helpers
  # ----------------------------------------------------------------

  # Returns {client, updated_clients_map}. Reuses an existing live client or starts
  # a fresh one (also restarts silently if the previous client's port has died).
  defp get_or_start_client(clients, cmd, args, file_path) do
    root = find_root(file_path)

    case Map.get(clients, cmd) do
      nil ->
        start_lsp_client(clients, cmd, args, root)

      client ->
        if client_alive?(client) do
          {client, clients}
        else
          # Port died between calls — start a replacement transparently.
          start_lsp_client(clients, cmd, args, root)
        end
    end
  end

  defp start_lsp_client(clients, cmd, args, root) do
    case Client.start(cmd, args, root) do
      {:ok, client} -> {client, Map.put(clients, cmd, client)}
      {:error, reason} -> raise "Failed to start LSP server #{cmd}: #{inspect(reason)}"
    end
  end

  defp client_alive?(%Client{port: port}) do
    Port.info(port) != nil
  rescue
    _ -> false
  end

  # ----------------------------------------------------------------
  # Content node graph helpers
  # ----------------------------------------------------------------

  # Add a content node map (from ContentStore) into the graph with its IMPLEMENTS edges.
  defp add_content_to_graph(graph, node) do
    id = node["id"]

    graph =
      CG.add_node(graph, id, node["type"], node["name"], %{
        content:    node["content"],
        created_at: node["created_at"],
        updated_at: node["updated_at"]
      })

    Enum.reduce(Map.get(node, "implements", []), graph, fn code_id, g ->
      # Only add the IMPLEMENTS edge if the code node exists in the graph.
      if code_id in Graph.vertices(g) do
        CG.add_edge(g, id, code_id, "IMPLEMENTS")
      else
        g
      end
    end)
  end

  # Reload all ContentStore nodes into an existing graph (called after index/load).
  defp reload_content_nodes(graph) do
    ContentStore.all()
    |> Enum.reduce(graph, fn node, g ->
      # Delete first so that updated content labels are applied correctly.
      g = Graph.delete_vertex(g, node["id"])
      add_content_to_graph(g, node)
    end)
  end

  # Put a map key only when the value is non-nil (for partial updates).
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Collect vertex IDs belonging to a file.
  defp file_node_ids(graph, file_path) do
    Graph.vertices(graph)
    |> Enum.filter(fn vid ->
      case CG.get_label(graph, vid) do
        %{file: ^file_path} -> true
        %{path: ^file_path} -> true
        _ -> false
      end
    end)
    |> MapSet.new()
  end

  # Persist incremental file changes to Neo4j: purge old nodes, upsert new ones + relevant edges.
  defp sync_file_to_neo4j(project, graph, file_path, file_node_set) do
    DirGraph.Neo4j.purge_file_nodes(project, file_path)

    nodes =
      file_node_set
      |> Enum.flat_map(fn vid ->
        case CG.get_label(graph, vid) do
          nil -> []
          n   -> [%{"node_id" => to_string(n[:id] || ""), "type" => to_string(n[:type] || ""),
                    "name"    => to_string(n[:name] || ""), "file" => to_string(n[:file] || ""),
                    "line"    => n[:line] || 0}]
        end
      end)

    edges =
      Graph.edges(graph)
      |> Enum.filter(fn e -> MapSet.member?(file_node_set, e.v1) or MapSet.member?(file_node_set, e.v2) end)
      |> Enum.map(fn e -> %{"source" => e.v1, "target" => e.v2, "rel" => to_string(e.label)} end)

    with :ok <- DirGraph.Neo4j.persist_project(project),
         :ok <- DirGraph.Neo4j.persist_nodes(project, nodes) do
      DirGraph.Neo4j.persist_edges(project, edges)
    end
  end

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
