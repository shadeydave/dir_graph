defmodule DirGraph.MCP.Allowlist do
  @moduledoc """
  Loads and enforces the MCP tool + path allowlist.

  ## Two-layer model

  1. **Static allowlist** — `.dir_graph/mcp_config.json`, edited by the user.
     This is the absolute ceiling: Claude can never access more than this permits.

  2. **Session plan** — `.dir_graph/session_plan.json`, written by Claude after
     proposing a plan for a specific task and receiving user approval.
     This can only RESTRICT the static allowlist (intersect tools, intersect paths,
     min depth) — it can never expand it.

  `load/0` is intentionally cheap (small JSON files) and called on every request
  so the plan takes effect immediately after approval without a server restart.

  ## Meta-tools

  Planning tools (`propose_session_plan`, `approve_session_plan`, `revoke_session_plan`)
  are only checked against the STATIC allowlist, not the session plan — otherwise a
  session plan could lock out the tools needed to revoke itself.
  """

  @config_path ".dir_graph/mcp_config.json"
  @plan_path ".dir_graph/session_plan.json"
  @draft_path ".dir_graph/session_plan.draft.json"

  @operational_tools ~w(
    query_code_graph
    affected_by
    find_tests
    workspace_stats
    semantic_search
    cross_project_search
    add_content_node
    update_content_node
    delete_content_node
    find_implementations
    list_content_nodes
    index_file
    index_directory
    load_graph
    save_graph
    watch_directory
    unwatch_directory
    sync_graph
    spawn_process
    list_processes
    read_output
    tail_output
    stop_process
    record_attempt
    resolve_problem
    list_problems
    reset_ledger
    export_to_viewer
    submit_viewer_diff
    neo4j_health
    neo4j_setup_schema
  )

  @meta_tools ~w(
    propose_session_plan
    approve_session_plan
    revoke_session_plan
  )

  @all_tools @operational_tools ++ @meta_tools

  @type t :: %{
          # What the static config allows (the ceiling)
          static_tools: [String.t()],
          static_paths: [String.t()],
          # Effective limits after session plan overlay
          allowed_tools: [String.t()],
          allowed_paths: [String.t()],
          max_search_depth: pos_integer(),
          # Active plan metadata (nil if no plan loaded)
          active_plan: map() | nil
        }

  @doc """
  Load config + active session plan from disk.
  Called on every tool invocation — no caching.
  """
  @spec load() :: t()
  def load do
    static = read_json(@config_path) || %{}
    base = normalize_static(static)

    case read_json(@plan_path) do
      nil ->
        Map.put(base, :active_plan, nil)

      plan ->
        apply_plan_overlay(base, plan)
    end
  end

  @doc "Returns true if `name` is allowed. Meta-tools bypass the session plan."
  @spec tool_allowed?(t(), String.t()) :: boolean()
  def tool_allowed?(allowlist, name) do
    if name in @meta_tools do
      name in allowlist.static_tools
    else
      name in allowlist.allowed_tools
    end
  end

  @doc "Returns the tool list visible to the current caller (meta-tools always included if static-allowed)."
  @spec effective_tools(t()) :: [String.t()]
  def effective_tools(allowlist) do
    meta = Enum.filter(@meta_tools, &(&1 in allowlist.static_tools))
    (allowlist.allowed_tools ++ meta) |> Enum.uniq()
  end

  @doc "Returns true if `path` is inside at least one approved directory."
  @spec path_allowed?(t(), String.t()) :: boolean()
  def path_allowed?(%{allowed_paths: allowed}, path) do
    abs = Path.expand(path)

    Enum.any?(allowed, fn dir ->
      abs_dir = Path.expand(dir)
      abs == abs_dir or String.starts_with?(abs, abs_dir <> "/")
    end)
  end

  @doc """
  Validates a proposed plan against the static allowlist and writes a draft file.
  Returns `{:ok, draft}` or `{:error, reason}`.
  """
  @spec write_draft(t(), map()) :: {:ok, map()} | {:error, String.t()}
  def write_draft(allowlist, proposal) do
    proposed_tools = coerce_tool_list(Map.get(proposal, "tools", allowlist.static_tools))
    proposed_paths = coerce_string_list(Map.get(proposal, "paths", allowlist.static_paths))
    proposed_depth = coerce_depth(Map.get(proposal, "max_depth", allowlist.max_search_depth))
    task = Map.get(proposal, "task", "Unnamed task")

    # Intersect against static limits — the plan can only restrict, never expand
    valid_tools = Enum.filter(proposed_tools, &(&1 in allowlist.static_tools))
    valid_paths = Enum.filter(proposed_paths, fn p ->
      path_allowed?(%{allowed_paths: allowlist.static_paths}, p)
    end)
    valid_depth = min(proposed_depth, allowlist.max_search_depth)

    draft = %{
      "task" => task,
      "status" => "draft",
      "allowed_tools" => valid_tools,
      "allowed_paths" => valid_paths,
      "max_search_depth" => valid_depth,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    dir = Path.dirname(@draft_path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(@draft_path, Jason.encode!(draft, pretty: true)) do
      {:ok, draft}
    else
      {:error, reason} -> {:error, "Failed to write draft: #{:file.format_error(reason)}"}
    end
  end

  @doc "Promotes the current draft to the live plan. Returns the plan or an error."
  @spec approve_draft() :: {:ok, map()} | {:error, String.t()}
  def approve_draft do
    case read_json(@draft_path) do
      nil ->
        {:error, "No draft found at #{@draft_path}. Call propose_session_plan first."}

      draft ->
        plan = Map.put(draft, "status", "approved")
        File.write!(@plan_path, Jason.encode!(plan, pretty: true))
        File.rm(@draft_path)
        {:ok, plan}
    end
  end

  @doc "Deletes the live plan and draft, restoring the full static allowlist."
  @spec revoke() :: :ok
  def revoke do
    File.rm(@plan_path)
    File.rm(@draft_path)
    :ok
  end

  @doc "Returns the paths for the draft and live plan files."
  def plan_paths, do: %{draft: @draft_path, live: @plan_path}

  # ----------------------------------------------------------------
  # Private
  # ----------------------------------------------------------------

  defp read_json(path) do
    with true <- File.exists?(path),
         {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw) do
      decoded
    else
      _ -> nil
    end
  end

  defp normalize_static(raw) do
    tools = coerce_tool_list(Map.get(raw, "allowed_tools", @all_tools))
    paths = coerce_string_list(Map.get(raw, "allowed_paths", ["."]))
    depth = coerce_depth(Map.get(raw, "max_search_depth", 3))

    %{
      static_tools: tools,
      static_paths: paths,
      allowed_tools: Enum.filter(tools, &(&1 in @operational_tools)),
      allowed_paths: paths,
      max_search_depth: depth,
      active_plan: nil
    }
  end

  defp apply_plan_overlay(base, plan) do
    plan_tools = coerce_tool_list(Map.get(plan, "allowed_tools", base.static_tools))
    plan_paths = coerce_string_list(Map.get(plan, "allowed_paths", base.static_paths))
    plan_depth = coerce_depth(Map.get(plan, "max_search_depth", base.max_search_depth))

    %{base |
      allowed_tools:
        base.allowed_tools
        |> Enum.filter(&(&1 in plan_tools))
        |> Enum.filter(&(&1 in @operational_tools)),
      allowed_paths: Enum.filter(base.static_paths, &(&1 in plan_paths)),
      max_search_depth: min(base.max_search_depth, plan_depth),
      active_plan: plan
    }
  end

  defp coerce_tool_list(list) when is_list(list),
    do: Enum.filter(list, &(is_binary(&1) and &1 in @all_tools))

  defp coerce_tool_list(_), do: @all_tools

  defp coerce_string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp coerce_string_list(_), do: ["."]

  defp coerce_depth(d) when is_integer(d) and d in 1..3, do: d
  defp coerce_depth(_), do: 4
end
