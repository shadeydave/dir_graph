defmodule DirGraph.VectorStore do
  @moduledoc """
  ETS-backed vector store with cosine similarity search.

  Holds one embedding vector per graph node ID. All operations are O(n) over
  stored vectors — sufficient for codebases up to ~50k nodes. For very large
  graphs an ANN index (e.g. HNSW) could replace the linear scan without
  changing the public API.

  Vectors are stored as plain Erlang lists of floats. The ETS table is
  `:protected` — reads happen in the caller's process, writes go through
  the GenServer to prevent races.
  """

  use GenServer

  @table :dir_graph_vectors

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Store `vector` for `node_id`. Overwrites any existing entry."
  @spec put(String.t(), [float()]) :: :ok
  def put(node_id, vector), do: GenServer.call(__MODULE__, {:put, node_id, vector})

  @doc "Remove the embedding for `node_id`."
  @spec delete(String.t()) :: :ok
  def delete(node_id), do: GenServer.call(__MODULE__, {:delete, node_id})

  @doc """
  Return the top-`k` node IDs most similar to `query_vector`, sorted by
  descending cosine similarity score.

  Returns `[{node_id, score}]`. Score is in [-1.0, 1.0]; 1.0 = identical direction.
  """
  @spec search([float()], pos_integer()) :: [{String.t(), float()}]
  def search(query_vector, k \\ 10) do
    # Read directly from ETS in the caller's process — no GenServer hop.
    :ets.tab2list(@table)
    |> Enum.map(fn {node_id, vector} ->
      {node_id, cosine_similarity(query_vector, vector)}
    end)
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
    |> Enum.take(k)
  end

  @doc "Delete all stored embeddings."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc "Number of stored embeddings."
  @spec size() :: non_neg_integer()
  def size do
    case :ets.info(@table, :size) do
      :undefined -> 0
      n -> n
    end
  end

  # ----------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :protected, :named_table])
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, node_id, vector}, _from, state) do
    :ets.insert(@table, {node_id, vector})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, node_id}, _from, state) do
    :ets.delete(@table, node_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # ----------------------------------------------------------------
  # Math
  # ----------------------------------------------------------------

  defp cosine_similarity(a, b) when length(a) == length(b) do
    {dot, sq_a, sq_b} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {d, sa, sb} ->
        {d + x * y, sa + x * x, sb + y * y}
      end)

    norm_a = :math.sqrt(sq_a)
    norm_b = :math.sqrt(sq_b)

    if norm_a == 0.0 or norm_b == 0.0, do: 0.0, else: dot / (norm_a * norm_b)
  end

  defp cosine_similarity(_, _), do: 0.0
end
