defmodule DirGraph.EnrichmentStore do
  @moduledoc """
  ETS-backed store for LLM-generated node enrichments produced by DirGraph.Dream.

  Each entry augments a graph node with structured metadata that goes beyond what
  the AST/LSP can extract: a plain-English summary, domain classification, semantic
  tags, and a complexity estimate. This enrichment is used by the RAG layer to build
  richer embedding text, dramatically improving semantic search recall.

  The table is `:protected` — reads happen in the caller's process, writes go through
  the GenServer to prevent races. The store survives graph rebuilds (node IDs are
  stable) but is cleared when the application restarts (ETS is in-memory only).
  Persistence to Neo4j is handled separately by DirGraph.Dream.
  """

  use GenServer

  @table :dir_graph_enrichments

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Store enrichment metadata for `node_id`. Overwrites any existing entry."
  @spec put(String.t(), map()) :: :ok
  def put(node_id, enrichment), do: GenServer.call(__MODULE__, {:put, node_id, enrichment})

  @doc "Retrieve enrichment for `node_id`, or `nil` if not yet enriched."
  @spec get(String.t()) :: map() | nil
  def get(node_id) do
    case :ets.lookup(@table, node_id) do
      [{_, enrichment}] -> enrichment
      [] -> nil
    end
  end

  @doc "Returns true if `node_id` has been enriched."
  @spec enriched?(String.t()) :: boolean()
  def enriched?(node_id), do: get(node_id) != nil

  @doc "Number of enriched nodes."
  @spec size() :: non_neg_integer()
  def size do
    case :ets.info(@table, :size) do
      :undefined -> 0
      n -> n
    end
  end

  @doc "All enriched node IDs."
  @spec all_ids() :: [String.t()]
  def all_ids, do: :ets.tab2list(@table) |> Enum.map(fn {id, _} -> id end)

  @doc "Delete all stored enrichments."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  # ----------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :protected, :named_table])
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, node_id, enrichment}, _from, state) do
    :ets.insert(@table, {node_id, enrichment})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
