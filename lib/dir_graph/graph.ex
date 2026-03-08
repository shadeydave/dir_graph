defmodule DirGraph.Graph do
  @moduledoc """
  Core graph builder wrapping libgraph.

  Vertices are STRING IDs (e.g. "Function:login/2:L45:/lib/auth.ex").
  Metadata (type, name, line, file, etc.) is stored as a libgraph vertex label map.
  Edges reference those same string IDs with a relationship-type label string.

  This keeps libgraph's identity model consistent: edges reference the same
  vertex values that were passed to add_vertex.
  """

  @doc "Initialize an empty directed graph."
  def new, do: Graph.new()

  @doc """
  Adds a node (vertex) to the graph.
  The `id` string is the vertex key. `type`, `name`, and `attributes` are stored
  as the vertex label map and are retrievable via `get_label/2`.
  If a vertex with the same `id` already exists it is NOT overwritten (libgraph no-op).
  """
  def add_node(graph, id, type, name, attributes \\ %{}) do
    label = Map.merge(%{type: type, name: name}, attributes)
    Graph.add_vertex(graph, id, label)
  end

  @doc """
  Adds a directed edge between two vertex IDs with a relationship label string.
  If either vertex does not yet exist, libgraph creates a bare vertex for it.
  """
  def add_edge(graph, source_id, target_id, edge_type) do
    Graph.add_edge(graph, source_id, target_id, label: edge_type)
  end

  @doc """
  Returns the label map for a vertex ID, or `nil` if the vertex has no label / doesn't exist.
  Always includes the vertex `id` field for convenience.
  """
  def get_label(graph, id) do
    case Graph.vertex_labels(graph, id) do
      [label | _] when is_map(label) -> Map.put(label, :id, id)
      _ -> nil
    end
  end

  @doc """
  Returns a list of all vertex label maps in the graph (one per vertex that has a label).
  Each map includes an `:id` key. Vertices without labels are omitted.
  """
  def all_nodes(graph) do
    graph
    |> Graph.vertices()
    |> Enum.flat_map(fn vid ->
      case get_label(graph, vid) do
        nil -> []
        label -> [label]
      end
    end)
  end
end
