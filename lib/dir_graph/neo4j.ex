defmodule DirGraph.Neo4j do
  @moduledoc """
  HTTP client for the DirGraph-dedicated Neo4j instance.

  Connects via Neo4j's transactional Cypher HTTP API — no extra dependencies,
  uses the `req` library already in the project.

  ## Start the container

      docker compose up -d

  Browser UI: http://localhost:7475  (credentials: neo4j / dirgraph)

  ## Configuration

  Override via environment variables or config/config.exs:

      DIRGRAPH_NEO4J_URL   (default: http://localhost:7475)
      DIRGRAPH_NEO4J_USER  (default: neo4j)
      DIRGRAPH_NEO4J_PASS  (default: dirgraph)
  """

  require Logger

  # ── connection ──────────────────────────────────────────────────────────────

  @doc """
  Returns `:ok` if Neo4j is reachable, `{:error, :neo4j_unreachable}` otherwise.
  Fast — 3 s timeout, no retries.
  """
  def ping do
    case Req.get(base_url() <> "/",
           auth: {:basic, auth()},
           retry: false,
           receive_timeout: 3_000
         ) do
      {:ok, %{status: 200}} -> :ok
      _ -> {:error, :neo4j_unreachable}
    end
  end

  @doc """
  Run a Cypher query. Returns `{:ok, [%{col => value}]}` or `{:error, reason}`.

  ## Examples

      Neo4j.query("MATCH (n:Project) RETURN n.name AS name")
      Neo4j.query("MATCH (n:ASTNode {project: $p}) RETURN n", %{p: "dir_graph"})
  """
  def query(cypher, params \\ %{}) do
    url  = base_url() <> "/db/neo4j/tx/commit"
    body = %{statements: [%{statement: cypher, parameters: params}]}

    case Req.post(url, json: body, auth: {:basic, auth()}, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"results" => results, "errors" => []}}} ->
        {:ok, parse_results(results)}

      {:ok, %{status: 200, body: %{"errors" => [err | _]}}} ->
        {:error, {:cypher_error, err["message"]}}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Same as `query/2` but raises on error. Use in setup/migration contexts.
  """
  def query!(cypher, params \\ %{}) do
    case query(cypher, params) do
      {:ok, rows} -> rows
      {:error, reason} -> raise "Neo4j query failed: #{inspect(reason)}\n#{cypher}"
    end
  end

  # ── schema ───────────────────────────────────────────────────────────────────

  @doc """
  Create the DirGraph schema: constraints, indexes, and the vector index for RAG.
  Safe to call multiple times — all statements use IF NOT EXISTS.
  Logs warnings for non-fatal issues (e.g. vector index requires Neo4j ≥ 5.11).
  """
  def setup_schema do
    statements = [
      # Project uniqueness
      """
      CREATE CONSTRAINT project_name IF NOT EXISTS
      FOR (p:Project) REQUIRE p.name IS UNIQUE
      """,

      # Fast node lookup by project + id
      """
      CREATE INDEX ast_node_lookup IF NOT EXISTS
      FOR (n:ASTNode) ON (n.project, n.node_id)
      """,

      # Fast edge lookup by project — one index per type (Cypher limitation)
      "CREATE INDEX ast_edge_calls IF NOT EXISTS FOR ()-[r:CALLS]-() ON (r.project)",
      "CREATE INDEX ast_edge_defines IF NOT EXISTS FOR ()-[r:DEFINES]-() ON (r.project)",
      "CREATE INDEX ast_edge_imports IF NOT EXISTS FOR ()-[r:IMPORTS]-() ON (r.project)",

      # Vector index for semantic search (Neo4j ≥ 5.11, built-in — no plugin needed).
      # Dimensionality matches nomic-embed-text (768) and OpenAI ada-002 (1536).
      # Change vector.dimensions if you switch embedding models.
      """
      CREATE VECTOR INDEX node_embeddings IF NOT EXISTS
      FOR (n:ASTNode) ON (n.embedding)
      OPTIONS {
        indexConfig: {
          `vector.dimensions`: 768,
          `vector.similarity_function`: 'cosine'
        }
      }
      """
    ]

    Enum.each(statements, fn stmt ->
      case query(stmt) do
        {:ok, _} ->
          :ok

        {:error, {:cypher_error, msg}} ->
          # Non-fatal — often fires on older Neo4j versions for the vector index
          Logger.warning("[DirGraph.Neo4j] Schema warning: #{msg}")

        {:error, reason} ->
          Logger.error("[DirGraph.Neo4j] Schema setup failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # ── health check helpers ─────────────────────────────────────────────────────

  @doc """
  Returns a human-readable message when Neo4j is not running.
  Shown in MCP tool responses and the viewer's error state.
  """
  def not_running_message do
    compose_path = compose_file_path()

    """
    DirGraph Neo4j is not running.

    Start it with:
      docker compose -f "#{compose_path}" up -d

    If Docker itself is not running, launch Docker Desktop first, then retry.

    Once started:
      Browser UI → http://localhost:7475   (neo4j / dirgraph)
      Bolt port  → localhost:7688
    """
  end

  @doc """
  Checks connectivity and returns a structured result for MCP tool responses.
  Returns `{:ok, info_map}` or `{:error, message_string}`.
  """
  def health_check do
    case ping() do
      :ok ->
        case query("CALL dbms.components() YIELD name, versions, edition RETURN name, versions, edition") do
          {:ok, [%{"versions" => [version | _], "edition" => edition} | _]} ->
            {:ok, %{status: "connected", version: version, edition: edition, url: base_url()}}

          _ ->
            {:ok, %{status: "connected", url: base_url()}}
        end

      {:error, :neo4j_unreachable} ->
        {:error, not_running_message()}
    end
  end

  # ── graph persistence ────────────────────────────────────────────────────────

  @doc """
  Upsert all nodes and edges from `graph` into Neo4j under `project`.
  Safe to call repeatedly — uses MERGE so re-indexing never duplicates.
  Runs synchronously; call inside a Task for non-blocking behaviour.
  """
  def persist_graph(project, graph) do
    alias DirGraph.Graph, as: CG

    nodes =
      CG.all_nodes(graph)
      |> Enum.map(fn n ->
        %{
          "node_id" => to_string(n[:id]   || ""),
          "type"    => to_string(n[:type] || ""),
          "name"    => to_string(n[:name] || ""),
          "file"    => to_string(n[:file] || ""),
          "line"    => n[:line] || 0
        }
      end)

    edges =
      Graph.edges(graph)
      |> Enum.map(fn e ->
        %{"source" => e.v1, "target" => e.v2, "rel" => to_string(e.label)}
      end)

    with :ok <- persist_project(project),
         :ok <- do_persist_nodes(project, nodes),
         :ok <- do_persist_edges(project, edges) do
      :ok
    end
  end

  @doc "Create or touch the Project node."
  def persist_project(project) do
    case query("MERGE (:Project {name: $name})", %{name: project}) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  @doc "Upsert a batch of node maps (each with node_id, type, name, file, line) into Neo4j."
  def persist_nodes(project, nodes), do: do_persist_nodes(project, nodes)

  @doc "Upsert a batch of edge maps (each with source, target, rel) into Neo4j."
  def persist_edges(project, edges), do: do_persist_edges(project, edges)

  @doc "Store the embedding vector on an ASTNode. No-op if the node is not in Neo4j yet."
  def update_embedding(node_id, project, embedding) do
    cypher = """
    MATCH (n:ASTNode {node_id: $node_id, project: $project})
    SET n.embedding = $embedding
    """
    case query(cypher, %{node_id: node_id, project: project, embedding: embedding}) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  @doc "Remove all ASTNodes (and their relationships) belonging to `file_path` in `project`."
  def purge_file_nodes(project, file_path) do
    cypher = """
    MATCH (n:ASTNode {project: $project, file: $file})
    DETACH DELETE n
    """
    case query(cypher, %{project: project, file: file_path}) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # Chunk + MERGE nodes in batches to avoid oversized HTTP payloads.
  defp do_persist_nodes(project, nodes) do
    cypher = """
    UNWIND $nodes AS n
    MERGE (node:ASTNode {node_id: n.node_id, project: $project})
    SET node.type = n.type,
        node.name = n.name,
        node.file = n.file,
        node.line = n.line
    """

    nodes
    |> Enum.chunk_every(500)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case query(cypher, %{nodes: batch, project: project}) do
        {:ok, _} -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  # Group edges by relationship type (Cypher doesn't allow parameterised rel types).
  # Only known types are constructed into queries — unknown types are dropped.
  @known_rels ~w(CALLS DEFINES IMPORTS CONTAINS IMPLEMENTS USES REQUIRES)

  defp do_persist_edges(project, edges) do
    edges
    |> Enum.group_by(& &1["rel"])
    |> Enum.filter(fn {rel, _} -> rel in @known_rels end)
    |> Enum.reduce_while(:ok, fn {rel, batch}, :ok ->
      cypher = """
      UNWIND $edges AS e
      MATCH (src:ASTNode {node_id: e.source, project: $project})
      MATCH (tgt:ASTNode {node_id: e.target, project: $project})
      MERGE (src)-[:#{rel} {project: $project}]->(tgt)
      """
      case query(cypher, %{edges: batch, project: project}) do
        {:ok, _} -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  # ── cross-project semantic search ────────────────────────────────────────────

  @doc """
  Vector similarity search across ALL indexed projects.
  Returns the top-K most similar ASTNodes, each with its project name and score.

  Requires Neo4j ≥ 5.11 and embeddings to have been stored on nodes.

  ## Example

      {:ok, hits} = Neo4j.semantic_search(embedding_vector, top_k: 10)
  """
  def semantic_search(embedding, opts \\ []) do
    top_k   = Keyword.get(opts, :top_k, 10)
    project = Keyword.get(opts, :project)   # nil = all projects

    filter  = if project, do: "WHERE n.project = $project", else: ""
    params  = %{embedding: embedding, top_k: top_k, project: project}

    cypher = """
    CALL db.index.vector.queryNodes('node_embeddings', $top_k, $embedding)
    YIELD node AS n, score
    #{filter}
    RETURN
      n.project    AS project,
      n.node_id    AS node_id,
      n.type       AS type,
      n.name       AS name,
      n.file       AS file,
      n.line       AS line,
      score
    ORDER BY score DESC
    """

    query(cypher, params)
  end

  # ── private ──────────────────────────────────────────────────────────────────

  defp base_url, do: Application.get_env(:dir_graph, :neo4j_url, "http://localhost:7475")
  # Returns "user:pass" so call sites can pass auth: {:basic, auth()}
  defp auth do
    user = Application.get_env(:dir_graph, :neo4j_user, "neo4j")
    pass = Application.get_env(:dir_graph, :neo4j_pass, "dirgraph")
    "#{user}:#{pass}"
  end

  defp parse_results([%{"columns" => cols, "data" => rows} | _]) do
    Enum.map(rows, fn %{"row" => values} ->
      Enum.zip(cols, values) |> Map.new()
    end)
  end

  defp parse_results(_), do: []

  defp compose_file_path do
    # Walk up from the compiled beam path to find the project root
    :code.priv_dir(:dir_graph)
    |> to_string()
    |> Path.join("../../docker-compose.yml")
    |> Path.expand()
  end
end
