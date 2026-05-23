defmodule DirGraph.LSP.SymbolMapper do
  @moduledoc """
  Converts an LSP DocumentSymbol tree into DirGraph graph nodes and edges.

  ## The lookup table

  LSP defines 26 SymbolKind integers (see the spec link below). This module
  maintains a declarative map from those integers to DirGraph node types.
  Adding a new kind or renaming a type requires only a map update here —
  no parser code changes.

  SymbolKind reference:
  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind

  ## Hierarchy → edges

  LSP DocumentSymbol is hierarchical: a `Class` symbol may have `Method`
  children. This maps directly to DEFINES edges:

      File ──CONTAINS──► Class ──DEFINES──► Method
                                └─DEFINES──► Constructor

  Symbols whose kind is not in the extract list are skipped, but their
  children are still walked so nested interesting symbols are not lost.

  ## Lines

  LSP uses 0-indexed lines. DirGraph uses 1-indexed. All line numbers are
  converted on ingestion here.
  """

  alias DirGraph.Graph, as: CG

  # ----------------------------------------------------------------
  # The lookup table: LSP SymbolKind integer → DirGraph node type
  # ----------------------------------------------------------------
  # Only kinds in this map become graph vertices.
  # Extend this map to capture additional LSP symbol types.

  @kind_type %{
    # Module
    2 => "Module",
    # Namespace
    3 => "Namespace",
    # Package
    4 => "Package",
    # Class
    5 => "Class",
    # Method
    6 => "Function",
    # Constructor
    9 => "Function",
    # Enum
    10 => "Enum",
    # Interface
    11 => "Interface",
    # Function
    12 => "Function",
    # Variable (top-level only — children filtered by depth)
    13 => "Variable",
    # Struct
    23 => "Struct",
    # TypeParameter
    26 => "TypeParameter"
  }

  @extract_kinds Map.keys(@kind_type)
  @variable_kind 13

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  @doc """
  Walks a DocumentSymbol list (hierarchical, with optional "children") and
  adds nodes + edges to `graph`.

  Returns `{updated_graph, refs}`. `refs` is always empty — import/cross-file
  edges are not surfaced by `documentSymbol` and are handled separately.
  """
  @spec symbols_to_graph([map()], String.t(), String.t(), Graph.t()) ::
          {Graph.t(), []}
  def symbols_to_graph(symbols, file_path, file_node_id, graph) when is_list(symbols) do
    Enum.reduce(symbols, {graph, []}, fn symbol, {g, refs} ->
      walk(symbol, file_node_id, file_node_id, file_path, g, refs)
    end)
  end

  def symbols_to_graph(_, _, _, graph), do: {graph, []}

  # ----------------------------------------------------------------
  # Tree walk
  # ----------------------------------------------------------------

  defp walk(symbol, parent_id, file_node_id, file_path, graph, refs) do
    kind = Map.get(symbol, "kind", 0)
    top_level = parent_id == file_node_id

    # Variables are only useful at module scope — local variables are noise.
    # A global `const BASE_URL` is a cross-cuttable fact; `const result = ...`
    # inside a function is not something the LLM needs to navigate to.
    include = kind in @extract_kinds and (kind != @variable_kind or top_level)

    if include do
      name = Map.get(symbol, "name", "unknown")
      type = Map.fetch!(@kind_type, kind)
      line = start_line(symbol)
      end_line = end_line(symbol)
      node_id = "#{type}:#{name}:L#{line}:#{file_path}"

      graph =
        CG.add_node(graph, node_id, type, name, %{
          line: line,
          end_line: end_line,
          file: file_path
        })

      edge = if parent_id == file_node_id, do: "CONTAINS", else: "DEFINES"
      graph = CG.add_edge(graph, parent_id, node_id, edge)

      # Recurse into children with this node as the new parent
      symbol
      |> Map.get("children", [])
      |> Enum.reduce({graph, refs}, fn child, {g, r} ->
        walk(child, node_id, file_node_id, file_path, g, r)
      end)
    else
      # Skip this node but still walk its children under the same parent
      symbol
      |> Map.get("children", [])
      |> Enum.reduce({graph, refs}, fn child, {g, r} ->
        walk(child, parent_id, file_node_id, file_path, g, r)
      end)
    end
  end

  # ----------------------------------------------------------------
  # Line extraction (LSP 0-indexed → DirGraph 1-indexed)
  # ----------------------------------------------------------------

  # Prefer selectionRange for the "name" start (more precise),
  # fall back to range start.
  defp start_line(symbol) do
    lsp_line(symbol, "selectionRange", "start") ||
      lsp_line(symbol, "range", "start") ||
      0
  end

  defp end_line(symbol) do
    lsp_line(symbol, "range", "end") ||
      lsp_line(symbol, "selectionRange", "end") ||
      0
  end

  defp lsp_line(symbol, range_key, bound) do
    case get_in(symbol, [range_key, bound, "line"]) do
      nil -> nil
      n -> n + 1
    end
  end
end
