defmodule DirGraph.RAG do
  @moduledoc """
  GraphRAG coordinator: embedding generation + semantic entry into the CPG.

  ## How it works

  Traditional graph queries start from a keyword match — you must know roughly
  what you're looking for. GraphRAG adds a semantic entry point:

  1. **Index** — each graph node is embedded (background, non-blocking). The
     embedding encodes the node's type, name, and source code into a dense vector
     that captures meaning rather than spelling.

  2. **Search** — a natural-language query is embedded with the same model, then
     compared against all stored node vectors via cosine similarity. The top-K
     most relevant node IDs are returned as graph entry points.

  3. **Traverse** — the caller (typically `DirGraph.Server`) does a standard BFS
     slice from each seed, merges the subgraphs, and returns a single compact
     payload with file + line per node.

  ## Background processing

  `index_file/2` and `index_graph/1` are GenServer casts — they return immediately
  and do the actual embedding work in a spawned process. This means indexing never
  blocks the rest of the system. The embedding store fills up over time as files
  are indexed, and search quality improves as more nodes are covered.

  ## Graceful degradation

  If the embedding backend is unreachable (Ollama not running, bad API key), nodes
  are silently skipped — they just won't appear in semantic search results. The
  rest of the tool continues to work normally. `semantic_search` returns
  `{:error, :backend_unavailable}` if the query itself cannot be embedded.
  """

  use GenServer

  alias DirGraph.{Embeddings, VectorStore, Neo4j}
  alias DirGraph.Graph, as: CG

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{project: nil}, name: __MODULE__)

  @doc "Tell RAG which project is currently active so embeddings are stored in Neo4j."
  def set_project(project_name) do
    GenServer.cast(__MODULE__, {:set_project, project_name})
  end

  @doc "Queue nodes for `file_path` in `graph` for background embedding."
  @spec index_file(Graph.t(), String.t()) :: :ok
  def index_file(graph, file_path) do
    GenServer.cast(__MODULE__, {:index_file, graph, file_path})
  end

  @doc "Queue all nodes in `graph` for background embedding."
  @spec index_graph(Graph.t()) :: :ok
  def index_graph(graph) do
    GenServer.cast(__MODULE__, {:index_graph, graph})
  end

  @doc "Embed a single node immediately given pre-built `text`. Fire-and-forget cast."
  @spec index_node(String.t(), String.t()) :: :ok
  def index_node(node_id, text) do
    GenServer.cast(__MODULE__, {:index_node, node_id, text})
  end

  @doc "Remove the embedding for `node_id` (call after purging a node from the graph)."
  @spec remove_node(String.t()) :: :ok
  def remove_node(node_id) do
    GenServer.cast(__MODULE__, {:remove_node, node_id})
  end

  @doc "Remove embeddings for all nodes belonging to `file_path`."
  @spec remove_file_nodes([String.t()]) :: :ok
  def remove_file_nodes(node_ids) do
    GenServer.cast(__MODULE__, {:remove_nodes, node_ids})
  end

  @doc """
  Embed `query` and return the `top_k` most similar node IDs with scores.
  Returns `{:ok, [{node_id, score}]}` or `{:error, reason}`.
  Blocks up to 30s for the embedding call.
  """
  @spec search(String.t(), pos_integer()) :: {:ok, [{String.t(), float()}]} | {:error, term()}
  def search(query, top_k \\ 10) do
    GenServer.call(__MODULE__, {:search, query, top_k}, 30_000)
  end

  @doc "Clear all stored embeddings."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc "Number of nodes with stored embeddings."
  @spec size() :: non_neg_integer()
  def size, do: VectorStore.size()

  # ----------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:set_project, project}, state) do
    {:noreply, %{state | project: project}}
  end

  @impl true
  def handle_cast({:index_node, node_id, text}, state) do
    project = state.project

    spawn(fn ->
      case Embeddings.embed(text) do
        {:ok, vector} ->
          VectorStore.put(node_id, vector)
          if project, do: Neo4j.update_embedding(node_id, project, vector)

        {:error, _} ->
          :skip
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:index_file, graph, file_path}, state) do
    project = state.project

    node_ids =
      Graph.vertices(graph)
      |> Enum.filter(fn vid ->
        case CG.get_label(graph, vid) do
          %{file: ^file_path} -> true
          %{path: ^file_path} -> true
          _ -> false
        end
      end)

    spawn(fn -> embed_nodes(graph, node_ids, project) end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:index_graph, graph}, state) do
    project = state.project
    node_ids = Graph.vertices(graph)
    spawn(fn -> embed_nodes(graph, node_ids, project) end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:remove_node, node_id}, state) do
    VectorStore.delete(node_id)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:remove_nodes, node_ids}, state) do
    Enum.each(node_ids, &VectorStore.delete/1)
    {:noreply, state}
  end

  @impl true
  def handle_call({:search, query, top_k}, _from, state) do
    result =
      case Embeddings.embed(query) do
        {:ok, vector} ->
          results = VectorStore.search(vector, top_k)

          if results == [] do
            {:error, :no_embeddings}
          else
            {:ok, results}
          end

        {:error, reason} ->
          {:error, {:backend_unavailable, reason}}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    VectorStore.clear()
    {:reply, :ok, state}
  end

  # ----------------------------------------------------------------
  # Embedding worker (runs in spawned process)
  # ----------------------------------------------------------------

  defp embed_nodes(graph, node_ids, project) do
    Enum.each(node_ids, fn node_id ->
      text = node_text(graph, node_id)

      case Embeddings.embed(text) do
        {:ok, vector} ->
          VectorStore.put(node_id, vector)
          if project, do: Neo4j.update_embedding(node_id, project, vector)

        {:error, _} ->
          :skip
      end
    end)
  end

  # Build a rich text representation for embedding. More signal = better recall.
  # Embeds type + name + source code for nodes with file/line info.
  defp node_text(graph, node_id) do
    case CG.get_label(graph, node_id) do
      nil ->
        node_id

      %{type: type, name: name, file: file, line: line} = meta ->
        end_line = Map.get(meta, :end_line)
        source = read_source(file, line, end_line)
        "#{type} #{name}\n#{source}"

      %{type: type, name: name, file: file} ->
        "#{type} #{name} in #{Path.basename(file)}"

      %{type: type, name: name} ->
        "#{type} #{name}"

      meta ->
        "#{Map.get(meta, :type, "node")} #{Map.get(meta, :name, node_id)}"
    end
  end

  defp read_source(nil, _line, _end_line), do: ""
  defp read_source(_file, nil, _end_line), do: ""

  defp read_source(file, start_line, end_line) do
    end_line = end_line || start_line

    with {:ok, content} <- File.read(file) do
      content
      |> String.split("\n")
      |> Enum.slice((start_line - 1)..(end_line - 1))
      |> Enum.join("\n")
    else
      _ -> ""
    end
  end
end
