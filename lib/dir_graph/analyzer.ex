defmodule DirGraph.Analyzer do
  @moduledoc """
  Traverses the graph to extract targeted semantic slices for LLM consumption.

  The key output of this module is `format_for_llm/2`, which produces a compact
  JSON-ready map containing only the nodes and edges relevant to a given concept,
  with full metadata (file path, line number) so an LLM can pinpoint exactly where
  to read without loading entire files.
  """

  alias DirGraph.Graph, as: CG

  @doc """
  Finds the vertex ID most closely matching `search_term`.

  1. Exact / substring match against the vertex ID string itself
  2. Substring match against the `name` label field
  3. Fuzzy Jaro-Winkler fallback (threshold 0.75) against the `name` label

  Returns the matched vertex ID string, or `nil` if nothing qualifies.
  """
  def find_node(graph, search_term) do
    term_lower = String.downcase(search_term)
    vertices = Graph.vertices(graph)

    # 1. Substring match on vertex ID or label name
    exact =
      Enum.find(vertices, fn vid ->
        name = get_name(graph, vid)

        String.contains?(String.downcase(vid), term_lower) or
          String.contains?(String.downcase(name), term_lower)
      end)

    if exact do
      exact
    else
      # 2. Fuzzy Jaro-Winkler match on label name
      threshold = 0.75

      vertices
      |> Enum.map(fn vid ->
        name = get_name(graph, vid)
        score = TheFuzz.Similarity.JaroWinkler.compare(String.downcase(name), term_lower)
        {vid, score}
      end)
      |> Enum.filter(fn {_vid, score} -> score >= threshold end)
      |> Enum.sort_by(fn {_vid, score} -> score end, :desc)
      |> case do
        [{vid, _} | _] -> vid
        [] -> nil
      end
    end
  end

  # Hard ceiling on BFS depth. Prevents exponential node explosion on
  # dense graphs (e.g. a file importing 10 modules, each with 20 symbols).
  # Depth 3 gives: matched node → its direct relations → their relations.
  # That's enough for the LLM to understand call chains without pulling in
  # the entire reachable subgraph.
  @max_depth 3

  @doc """
  BFS from `start_vertex_id` up to `depth` hops in BOTH directions, building a subgraph.
  Returns the libgraph subgraph containing only the collected nodes and their edges.
  Depth is silently capped at #{@max_depth} regardless of the requested value.
  """
  def extract_slice(graph, start_vertex_id, depth \\ 2) do
    collected = bfs(graph, [start_vertex_id], min(depth, @max_depth), MapSet.new([start_vertex_id]))
    Graph.subgraph(graph, MapSet.to_list(collected))
  end

  @doc """
  Follows only inbound edges from `start_vertex_id` — "what calls/uses/imports me?"
  Returns a subgraph of all nodes that would be affected if `start_vertex_id` changes.
  Depth is silently capped at #{@max_depth}.
  """
  def affected_by(graph, start_vertex_id, depth \\ 2) do
    collected = bfs_in(graph, [start_vertex_id], min(depth, @max_depth), MapSet.new([start_vertex_id]))
    Graph.subgraph(graph, MapSet.to_list(collected))
  end

  @doc """
  Formats a subgraph into a compact map for LLM context injection.

  Each node entry includes all available metadata: id, type, name, file path, and
  line number. This lets an LLM (or Claude Code) issue targeted `Read` calls with
  exact line offsets rather than loading whole files.

  Options:
  - `include_types` — filter to a list of type strings, or `:all` (default)
  - `include_code`  — when `true`, embed actual source lines per node as `code` field,
                      eliminating the need for separate Read calls (default `false`)

  Edge entries include source, target, and the relationship label.
  """
  def format_for_llm(subgraph, opts \\ []) do
    include_types = Keyword.get(opts, :include_types, :all)
    include_code  = Keyword.get(opts, :include_code,  false)

    nodes =
      subgraph
      |> Graph.vertices()
      |> Enum.flat_map(fn vid ->
        label = Graph.vertex_labels(subgraph, vid)

        meta =
          case label do
            [m | _] when is_map(m) -> m
            _ -> %{}
          end

        type = Map.get(meta, :type, "unknown")

        if include_types == :all or type in include_types do
          node =
            %{
              id: vid,
              type: type,
              name: Map.get(meta, :name, vid),
              file: Map.get(meta, :file),
              line: Map.get(meta, :line),
              end_line: Map.get(meta, :end_line),
              visibility: Map.get(meta, :visibility),
              label: Map.get(meta, :label)
            }
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Enum.into(%{})

          node =
            if include_code and is_binary(node[:file]) and is_integer(node[:line]) do
              Map.put(node, :code, read_node_source(node.file, node.line, node[:end_line]))
            else
              node
            end

          [node]
        else
          []
        end
      end)

    edges =
      subgraph
      |> Graph.edges()
      |> Enum.map(fn edge ->
        %{source: edge.v1, target: edge.v2, rel: edge.label}
      end)

    %{
      node_count: length(nodes),
      edge_count: length(edges),
      nodes: nodes,
      edges: edges
    }
  end

  @doc """
  Prints a human-readable summary of the slice — useful for interactive CLI inspection.
  """
  def print_slice_summary(payload) do
    IO.puts("\n=== Semantic Slice (#{payload.node_count} nodes, #{payload.edge_count} edges) ===\n")

    payload.nodes
    |> Enum.group_by(& &1.type)
    |> Enum.each(fn {type, nodes} ->
      IO.puts("  [#{type}]")

      Enum.each(nodes, fn node ->
        location =
          if node[:file] do
            short = Path.relative_to_cwd(node.file)
            line = if node[:line], do: ":#{node.line}", else: ""
            " (#{short}#{line})"
          else
            ""
          end

        IO.puts("    #{node.name}#{location}")
      end)
    end)

    IO.puts("\n  Relationships:")

    Enum.each(payload.edges, fn edge ->
      source_short = String.slice(edge.source, -60, 60)
      target_short = String.slice(edge.target, -60, 60)
      IO.puts("    #{source_short} --[#{edge.rel}]--> #{target_short}")
    end)

    IO.puts("")
  end

  # ----------------------------------------------------------------
  # BFS helpers
  # ----------------------------------------------------------------

  defp bfs(_graph, _frontier, 0, visited), do: visited
  defp bfs(_graph, [], _depth, visited), do: visited

  defp bfs(graph, frontier, depth, visited) do
    next =
      frontier
      |> Enum.flat_map(fn node ->
        Graph.out_neighbors(graph, node) ++ Graph.in_neighbors(graph, node)
      end)
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    new_visited = Enum.reduce(next, visited, &MapSet.put(&2, &1))
    bfs(graph, next, depth - 1, new_visited)
  end

  # Inbound-only BFS — follows edges arriving at each node (callers/importers).
  defp bfs_in(_graph, _frontier, 0, visited), do: visited
  defp bfs_in(_graph, [], _depth, visited), do: visited

  defp bfs_in(graph, frontier, depth, visited) do
    next =
      frontier
      |> Enum.flat_map(&Graph.in_neighbors(graph, &1))
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    new_visited = Enum.reduce(next, visited, &MapSet.put(&2, &1))
    bfs_in(graph, next, depth - 1, new_visited)
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp get_name(graph, vid) do
    case CG.get_label(graph, vid) do
      %{name: name} -> name
      _ -> vid
    end
  end

  # Reads source lines for a node. Returns a string or nil if the file can't be read.
  defp read_node_source(file, start_line, end_line) do
    end_line = end_line || start_line

    with {:ok, content} <- File.read(file) do
      content
      |> String.split("\n")
      |> Enum.slice((start_line - 1)..(end_line - 1))
      |> Enum.join("\n")
    else
      _ -> nil
    end
  end
end
