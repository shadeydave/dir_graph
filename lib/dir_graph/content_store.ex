defmodule DirGraph.ContentStore do
  @moduledoc """
  Persistent store for Content nodes — the non-code layer of the CPG.

  Content nodes capture business knowledge that lives ABOVE the code:
  business rules, UI copy, API contracts, domain concepts. They connect
  to code via `IMPLEMENTS` edges, enabling "edit once, distribute everywhere"
  traceability: change the rule, find every function that must change with it.

  ## Node types

  - **BusinessRule** — invariants, policies, constraints ("dual approval > $10k")
  - **Copy** — UI text, emails, notifications, marketing strings
  - **Contract** — API specs, data shapes, interface agreements
  - **Domain** — bounded contexts, ubiquitous language, domain concepts

  ## Persistence

  Nodes are stored as JSON in `.dir_graph/content_nodes.json`. This file is the
  source of truth and survives graph rebuilds — content nodes are reloaded into
  the in-memory graph after every `index_directory` and `load_graph` call.

  ## Format

      [
        {
          "id": "BusinessRule:payment_approval",
          "type": "BusinessRule",
          "name": "Payment Approval Rule",
          "content": "All payments over $10k require dual approval from Finance and Legal.",
          "implements": ["Function:check_payment_limit", "Module:PaymentApproval"],
          "created_at": "2024-01-15T10:30:00Z",
          "updated_at": "2024-01-15T10:30:00Z"
        }
      ]
  """

  @store_path ".dir_graph/content_nodes.json"

  @valid_types ~w(BusinessRule Copy Contract Domain)

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  @doc "All valid content node types."
  def valid_types, do: @valid_types

  @doc """
  Create or update a content node. Returns `{:ok, node}` or `{:error, reason}`.
  The node map must have string keys: `"id"`, `"type"`, `"name"`, `"content"`.
  """
  @spec put(map()) :: {:ok, map()} | {:error, String.t()}
  def put(node) do
    nodes = all() |> Map.new(fn n -> {n["id"], n} end)
    updated = Map.put(nodes, node["id"], node)

    case write(Map.values(updated)) do
      :ok -> {:ok, node}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Get a content node by ID. Returns the node map or `nil`."
  @spec get(String.t()) :: map() | nil
  def get(id) do
    Enum.find(all(), fn n -> n["id"] == id end)
  end

  @doc "Delete a content node by ID. Returns `:ok` whether or not it existed."
  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(id) do
    nodes = all() |> Enum.reject(fn n -> n["id"] == id end)
    write(nodes)
  end

  @doc "Return all stored content nodes as a list of maps."
  @spec all() :: [map()]
  def all do
    with true <- File.exists?(@store_path),
         {:ok, raw} <- File.read(@store_path),
         {:ok, list} when is_list(list) <- Jason.decode(raw) do
      list
    else
      _ -> []
    end
  end

  @doc """
  Add `code_node_id` to the `implements` list of node `id`.
  No-op if already present. Returns `{:ok, node}` or `{:error, reason}`.
  """
  @spec add_link(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def add_link(id, code_node_id) do
    case get(id) do
      nil ->
        {:error, "Content node '#{id}' not found."}

      node ->
        links = Map.get(node, "implements", [])

        updated =
          Map.put(node, "implements", Enum.uniq([code_node_id | links]))
          |> Map.put("updated_at", now())

        put(updated)
    end
  end

  @doc """
  Remove `code_node_id` from the `implements` list of node `id`.
  Returns `{:ok, node}` or `{:error, reason}`.
  """
  @spec remove_link(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def remove_link(id, code_node_id) do
    case get(id) do
      nil ->
        {:error, "Content node '#{id}' not found."}

      node ->
        links = Map.get(node, "implements", []) |> Enum.reject(&(&1 == code_node_id))

        updated =
          Map.put(node, "implements", links)
          |> Map.put("updated_at", now())

        put(updated)
    end
  end

  @doc "Build a content node ID from type + name slug."
  @spec make_id(String.t(), String.t()) :: String.t()
  def make_id(type, name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    "#{type}:#{slug}"
  end

  @doc "Returns the file path for the store (useful for tooling)."
  def store_path, do: @store_path

  # ----------------------------------------------------------------
  # Private
  # ----------------------------------------------------------------

  defp write(nodes) do
    dir = Path.dirname(@store_path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(@store_path, Jason.encode!(nodes, pretty: true)) do
      :ok
    else
      {:error, reason} -> {:error, "Failed to write content store: #{:file.format_error(reason)}"}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
