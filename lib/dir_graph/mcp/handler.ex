defmodule DirGraph.MCP.Handler do
  @moduledoc """
  Handles MCP JSON-RPC 2.0 messages and dispatches tool calls.

  The allowlist is passed fresh on every call (reloaded from disk by the server
  loop), so session plan changes take effect on the next request with no restart.

  ## Tool categories

  **Operational** (restricted by session plan when active):
    - `query_code_graph` — search the graph for a concept
    - `index_directory` / `index_file` — build/update the in-memory graph
    - `load_graph` / `save_graph` — persist the graph to disk

  **Meta** (only restricted by static allowlist, never by session plan):
    - `propose_session_plan` — draft a restricted tool/path set for a task
    - `approve_session_plan` — commit the draft as the live session plan
    - `revoke_session_plan` — clear the plan, restore full static allowlist
  """

  alias DirGraph.MCP.Allowlist

  @server_name "dir_graph"
  @server_version "0.1.0"
  @protocol_version "2024-11-05"

  # ----------------------------------------------------------------
  # MCP lifecycle
  # ----------------------------------------------------------------

  def handle(%{"method" => "initialize", "id" => id}, _allowlist) do
    reply(id, %{
      protocolVersion: @protocol_version,
      capabilities: %{tools: %{}},
      serverInfo: %{name: @server_name, version: @server_version}
    })
  end

  def handle(%{"method" => "notifications/initialized"}, _), do: nil

  # ----------------------------------------------------------------
  # tools/list — reflects current allowlist + active plan
  # ----------------------------------------------------------------

  def handle(%{"method" => "tools/list", "id" => id}, allowlist) do
    tools =
      allowlist
      |> Allowlist.effective_tools()
      |> Enum.map(&tool_schema/1)

    plan_notice =
      case allowlist.active_plan do
        nil -> nil
        plan -> %{active_session_plan: %{task: plan["task"], tools: plan["allowed_tools"], paths: plan["allowed_paths"]}}
      end

    result = if plan_notice, do: Map.merge(%{tools: tools}, plan_notice), else: %{tools: tools}
    reply(id, result)
  end

  # ----------------------------------------------------------------
  # tools/call
  # ----------------------------------------------------------------

  def handle(
        %{"method" => "tools/call", "id" => id,
          "params" => %{"name" => name, "arguments" => args}},
        allowlist
      ) do
    result =
      if Allowlist.tool_allowed?(allowlist, name) do
        call_tool(name, args, allowlist)
      else
        %{
          error: true,
          message: "Tool '#{name}' is not permitted under the current allowlist.",
          allowed_tools: Allowlist.effective_tools(allowlist),
          hint:
            if(allowlist.active_plan,
              do: "An active session plan is restricting your tools. Call revoke_session_plan to clear it.",
              else: "Edit .dir_graph/mcp_config.json to add this tool to allowed_tools."
            )
        }
      end

    text = Jason.encode!(result, pretty: true)
    reply(id, %{content: [%{type: "text", text: text}]})
  end

  def handle(%{"method" => "ping", "id" => id}, _), do: reply(id, %{})

  def handle(%{"id" => id, "method" => method}, _) do
    %{jsonrpc: "2.0", id: id,
      error: %{code: -32_601, message: "Method not found: #{method}"}}
  end

  def handle(_notification, _), do: nil

  # ----------------------------------------------------------------
  # Operational tools
  # ----------------------------------------------------------------

  defp call_tool("query_code_graph", args, allowlist) do
    term         = Map.get(args, "search_term", "")
    depth        = args |> Map.get("depth", 2) |> min(allowlist.max_search_depth)
    include_code = Map.get(args, "include_code", false)

    case DirGraph.Server.extract_slice(term, depth: depth, include_code: include_code) do
      {:ok, payload} -> payload
      {:error, :not_found} -> %{error: true, message: "No node found matching '#{term}'"}
    end
  end

  defp call_tool("affected_by", args, allowlist) do
    term         = Map.get(args, "search_term", "")
    depth        = args |> Map.get("depth", 2) |> min(allowlist.max_search_depth)
    include_code = Map.get(args, "include_code", false)

    case DirGraph.Server.affected_by(term, depth: depth, include_code: include_code) do
      {:ok, payload} -> payload
      {:error, :not_found} -> %{error: true, message: "No node found matching '#{term}'"}
    end
  end

  defp call_tool("workspace_stats", _args, _allowlist) do
    DirGraph.Server.workspace_stats()
  end

  # ----------------------------------------------------------------
  # Content node tools
  # ----------------------------------------------------------------

  defp call_tool("add_content_node", args, _allowlist) do
    case DirGraph.Server.add_content_node(args) do
      {:ok, node}      -> Map.put(node, "status", "created")
      {:error, reason} -> %{error: true, message: reason}
    end
  end

  defp call_tool("update_content_node", %{"id" => id} = args, _allowlist) do
    case DirGraph.Server.update_content_node(id, args) do
      {:ok, node}      -> Map.put(node, "status", "updated")
      {:error, reason} -> %{error: true, message: reason}
    end
  end

  defp call_tool("delete_content_node", %{"id" => id}, _allowlist) do
    case DirGraph.Server.delete_content_node(id) do
      :ok              -> %{status: "deleted", id: id}
      {:error, reason} -> %{error: true, message: reason}
    end
  end

  defp call_tool("find_implementations", %{"id" => id}, _allowlist) do
    case DirGraph.Server.find_implementations(id) do
      {:ok, result}    -> result
      {:error, reason} -> %{error: true, message: reason}
    end
  end

  defp call_tool("list_content_nodes", args, _allowlist) do
    type = Map.get(args, "type")

    case DirGraph.Server.list_content_nodes(type) do
      {:ok, nodes} ->
        %{
          count: length(nodes),
          nodes: nodes,
          hint: if(nodes == [], do: "No content nodes yet. Use add_content_node to capture business rules, copy, contracts, and domain concepts.", else: nil)
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      {:error, reason} ->
        %{error: true, message: reason}
    end
  end

  defp call_tool("semantic_search", args, allowlist) do
    query        = Map.get(args, "query", "")
    top_k        = Map.get(args, "top_k", 5)
    depth        = args |> Map.get("depth", 2) |> min(allowlist.max_search_depth)
    include_code = Map.get(args, "include_code", false)

    case DirGraph.Server.semantic_search(query, top_k: top_k, depth: depth, include_code: include_code) do
      {:ok, payload} ->
        payload

      {:error, :no_embeddings} ->
        %{
          error: true,
          message: "No embeddings are stored yet. Embeddings are built in the background after indexing — wait a moment and try again, or check that an embedding backend (Ollama/OpenAI) is configured and reachable.",
          hint: "Run workspace_stats to see how many nodes are embedded so far."
        }

      {:error, {:backend_unavailable, reason}} ->
        %{
          error: true,
          message: "Embedding backend unavailable: #{inspect(reason)}",
          hint: "For Ollama: run `ollama serve` and `ollama pull nomic-embed-text`. For OpenAI: set OPENAI_API_KEY and add the embeddings config to .dir_graph/mcp_config.json."
        }

      {:error, reason} ->
        %{error: true, message: "Semantic search failed: #{inspect(reason)}"}
    end
  end

  defp call_tool("index_directory", %{"path" => path}, allowlist) do
    with :ok <- check_path(path, allowlist) do
      DirGraph.Server.index_directory(path)
      graph = DirGraph.Server.get_graph()
      n = Graph.vertices(graph) |> length()
      e = Graph.edges(graph) |> length()
      %{status: "ok", message: "Indexed #{path}", nodes: n, edges: e}
    end
  end

  defp call_tool("index_file", %{"path" => path}, allowlist) do
    with :ok <- check_path(path, allowlist),
         true <- File.exists?(path) || path_error("File not found", path) do
      DirGraph.Server.index_file(path)
      %{status: "ok", message: "Indexed #{path}"}
    end
  end

  defp call_tool("load_graph", %{"path" => path}, allowlist) do
    with :ok <- check_path(path, allowlist),
         true <- File.exists?(path) || path_error("File not found", path) do
      DirGraph.Server.load(path)
      graph = DirGraph.Server.get_graph()
      n = Graph.vertices(graph) |> length()
      e = Graph.edges(graph) |> length()
      %{status: "ok", message: "Loaded graph from #{path}", nodes: n, edges: e}
    end
  end

  defp call_tool("save_graph", %{"path" => path}, allowlist) do
    with :ok <- check_path(path, allowlist) do
      graph = DirGraph.Server.get_graph()
      DirGraph.Indexer.save_graph(graph, path)
      %{status: "ok", message: "Graph saved to #{path}"}
    end
  end

  defp call_tool("watch_directory", %{"path" => path}, allowlist) do
    with :ok <- check_path(path, allowlist) do
      case DirGraph.Watcher.watch(path) do
        :ok              -> %{status: "ok", message: "Now watching #{path} for changes."}
        :already_watching -> %{status: "ok", message: "Already watching #{path}."}
        {:error, reason} -> %{error: true, message: "Failed to watch #{path}: #{inspect(reason)}"}
      end
    end
  end

  defp call_tool("unwatch_directory", %{"path" => path}, _allowlist) do
    case DirGraph.Watcher.unwatch(path) do
      :ok           -> %{status: "ok", message: "Stopped watching #{path}."}
      :not_watching -> %{status: "ok", message: "#{path} was not being watched."}
    end
  end

  defp call_tool("sync_graph", %{"path" => path}, allowlist) do
    with :ok <- check_path(path, allowlist) do
      case DirGraph.Server.sync(path) do
        {:ok, %{new: n, modified: m, deleted: d}} ->
          %{
            status: "ok",
            message: "Sync complete.",
            new: n, modified: m, deleted: d,
            total_changes: n + m + d
          }
      end
    end
  end

  # ----------------------------------------------------------------
  # Process monitor tools
  # ----------------------------------------------------------------

  defp call_tool("spawn_process", %{"name" => name, "cmd" => cmd} = args, allowlist) do
    cwd = Map.get(args, "cwd", ".")

    with :ok <- check_path(cwd, allowlist) do
      case DirGraph.ProcessMonitor.spawn_process(name, cmd, Path.expand(cwd)) do
        {:ok, ^name}             -> %{status: "ok", name: name, message: "Process '#{name}' started."}
        {:error, {:name_taken, _}} -> %{error: true, message: "A process named '#{name}' is already running. Stop it first or choose a different name."}
        {:error, reason}         -> %{error: true, message: "Failed to spawn process: #{inspect(reason)}"}
      end
    end
  end

  defp call_tool("list_processes", _args, _allowlist) do
    %{processes: DirGraph.ProcessMonitor.list_processes()}
  end

  defp call_tool("read_output", %{"name" => name} = args, _allowlist) do
    limit = Map.get(args, "limit", 50)

    case DirGraph.ProcessMonitor.read_output(name, limit) do
      {:ok, result}        -> result
      {:error, :not_found} -> %{error: true, message: "No process named '#{name}'. Call list_processes to see what's running."}
    end
  end

  defp call_tool("tail_output", %{"name" => name} = args, _allowlist) do
    cursor = Map.get(args, "cursor", 0)

    case DirGraph.ProcessMonitor.tail_output(name, cursor) do
      {:ok, result}        -> result
      {:error, :not_found} -> %{error: true, message: "No process named '#{name}'. Call list_processes to see what's running."}
    end
  end

  defp call_tool("stop_process", %{"name" => name}, _allowlist) do
    case DirGraph.ProcessMonitor.stop_process(name) do
      :ok                  -> %{status: "ok", message: "Process '#{name}' stopped."}
      {:error, :not_found} -> %{error: true, message: "No process named '#{name}'."}
    end
  end

  defp call_tool("find_tests", %{"search_term" => term} = args, allowlist) do
    depth = Map.get(args, "depth", 3)
    Allowlist.check!(allowlist, "find_tests", nil)
    case DirGraph.Server.find_tests(term, depth: depth) do
      {:ok, result}          -> result
      {:error, :not_found}   -> %{error: "No node matching '#{term}' found in graph."}
    end
  end

  defp call_tool("record_attempt", %{"key" => key} = args, _allowlist) do
    diagnostic = Map.get(args, "diagnostic")
    DirGraph.AttemptLedger.record_attempt(key, diagnostic)
  end

  defp call_tool("resolve_problem", %{"key" => key}, _allowlist) do
    DirGraph.AttemptLedger.resolve_problem(key)
    %{status: "ok", message: "'#{key}' marked as resolved. If it recurs, record_attempt will flag it as a regression."}
  end

  defp call_tool("list_problems", _args, _allowlist) do
    %{problems: DirGraph.AttemptLedger.list_problems()}
  end

  defp call_tool("reset_ledger", _args, _allowlist) do
    DirGraph.AttemptLedger.reset_all()
    %{status: "ok", message: "Attempt ledger cleared."}
  end

  # ----------------------------------------------------------------
  # Meta / planning tools
  # ----------------------------------------------------------------

  defp call_tool("propose_session_plan", args, allowlist) do
    case Allowlist.write_draft(allowlist, args) do
      {:ok, draft} ->
        paths = Allowlist.plan_paths()

        %{
          status: "draft_written",
          message: """
          Session plan draft written to #{paths.draft}.
          Review the plan below, then call approve_session_plan to activate it,
          or adjust the arguments and call propose_session_plan again.
          """,
          draft: draft,
          next_steps: %{
            approve: "Call approve_session_plan (no arguments) to activate this plan.",
            revise: "Call propose_session_plan again with updated arguments.",
            skip: "Do nothing — the draft has no effect until approved."
          }
        }

      {:error, reason} ->
        %{error: true, message: reason}
    end
  end

  defp call_tool("approve_session_plan", _args, _allowlist) do
    case Allowlist.approve_draft() do
      {:ok, plan} ->
        %{
          status: "plan_active",
          message: "Session plan approved and now active. Tool calls will be restricted until revoke_session_plan is called.",
          active_plan: plan
        }

      {:error, reason} ->
        %{error: true, message: reason}
    end
  end

  defp call_tool("revoke_session_plan", _args, _allowlist) do
    Allowlist.revoke()
    %{
      status: "plan_revoked",
      message: "Session plan cleared. Full static allowlist is now in effect."
    }
  end

  defp call_tool("cross_project_search", args, _allowlist) do
    query   = Map.get(args, "query", "")
    top_k   = Map.get(args, "top_k", 10)
    project = Map.get(args, "project")

    case DirGraph.Neo4j.ping() do
      {:error, :neo4j_unreachable} ->
        %{error: true, message: DirGraph.Neo4j.not_running_message()}

      :ok ->
        case DirGraph.Embeddings.embed(query) do
          {:ok, vector} ->
            opts = [top_k: top_k] ++ if(project, do: [project: project], else: [])

            case DirGraph.Neo4j.semantic_search(vector, opts) do
              {:ok, []} ->
                %{results: [], message: "No matching nodes found. Embeddings may not be fully built yet — wait for background indexing or check that an embedding backend is running."}

              {:ok, hits} ->
                %{query: query, total: length(hits), results: hits}

              {:error, reason} ->
                %{error: true, message: "Search failed: #{inspect(reason)}"}
            end

          {:error, reason} ->
            %{
              error: true,
              message: "Embedding backend unavailable: #{inspect(reason)}",
              hint: "For Ollama: run `ollama serve` and `ollama pull nomic-embed-text`."
            }
        end
    end
  end

  defp call_tool("submit_viewer_diff", args, _allowlist) do
    project       = Map.get(args, "project", "")
    label         = Map.get(args, "label", "AI diff")
    added_nodes   = Map.get(args, "added_nodes", [])
    removed_nodes = Map.get(args, "removed_nodes", [])
    added_edges   = Map.get(args, "added_edges", [])
    removed_edges = Map.get(args, "removed_edges", [])
    annotations   = Map.get(args, "annotations", [])

    ledger_path = Path.expand("~/sites/diffs/#{project}/diff_ledger.json")

    with {:ok, raw}    <- File.read(ledger_path),
         {:ok, ledger} <- Jason.decode(raw) do
      diffs     = ledger["diffs"] || []
      last_id   = diffs |> List.last() |> then(&((&1 && &1["diff_id"]) || 0))
      new_id    = last_id + 1

      diff = %{
        "diff_id"        => new_id,
        "parent_diff_id" => last_id,
        "author"         => "ai",
        "label"          => label,
        "added_nodes"    => added_nodes,
        "removed_nodes"  => removed_nodes,
        "added_edges"    => added_edges,
        "removed_edges"  => removed_edges,
        "annotations"    => annotations,
        "timestamp"      => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      new_ledger = Map.put(ledger, "diffs", diffs ++ [diff])

      case File.write(ledger_path, Jason.encode!(new_ledger, pretty: true)) do
        :ok ->
          %{
            status: "ok",
            diff_id: new_id,
            message: "Diff ##{new_id} submitted to '#{project}' ledger. The viewer will display it within 2 seconds.",
            summary: %{
              added_nodes:   length(added_nodes),
              removed_nodes: length(removed_nodes),
              added_edges:   length(added_edges),
              removed_edges: length(removed_edges),
              annotations:   length(annotations)
            }
          }

        {:error, reason} ->
          %{error: true, message: "Failed to write ledger: #{:file.format_error(reason)}"}
      end
    else
      {:error, :enoent} ->
        %{error: true, message: "No ledger found for project '#{project}'. Run export_to_viewer first to initialise the viewer session."}

      {:error, reason} ->
        %{error: true, message: "Failed to read ledger: #{inspect(reason)}"}
    end
  end

  defp call_tool("export_to_viewer", %{"project" => project}, _allowlist) do
    DirGraph.Server.export_viewer_data(project)
  end

  defp call_tool("neo4j_health", _args, _allowlist) do
    case DirGraph.Neo4j.health_check() do
      {:ok, info}      -> Map.put(info, :hint, "Run setup_schema to initialise indexes if this is a fresh container.")
      {:error, message} -> %{error: true, message: message}
    end
  end

  defp call_tool("neo4j_setup_schema", _args, _allowlist) do
    case DirGraph.Neo4j.ping() do
      :ok ->
        DirGraph.Neo4j.setup_schema()
        %{status: "ok", message: "Schema initialised. Constraints, indexes, and vector index are ready."}

      {:error, :neo4j_unreachable} ->
        %{error: true, message: DirGraph.Neo4j.not_running_message()}
    end
  end

  defp call_tool(name, _args, _allowlist) do
    %{error: true, message: "Unknown tool: #{name}"}
  end

  # ----------------------------------------------------------------
  # Path guard
  # ----------------------------------------------------------------

  defp check_path(path, allowlist) do
    if Allowlist.path_allowed?(allowlist, path) do
      :ok
    else
      %{
        error: true,
        message: "Path '#{path}' is outside the approved directories.",
        allowed_paths: allowlist.allowed_paths
      }
    end
  end

  defp path_error(msg, path), do: %{error: true, message: "#{msg}: #{path}"}

  # ----------------------------------------------------------------
  # Tool schemas
  # ----------------------------------------------------------------

  defp tool_schema("query_code_graph") do
    %{
      name: "query_code_graph",
      description: """
      Search the code graph for a concept, function, module, or class name.
      Returns a semantic slice: all related nodes within `depth` hops, each with
      file path and line number. Set include_code=true to embed the actual source
      lines directly in the response, eliminating separate Read calls.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          search_term:  %{type: "string",  description: "Function, module, or concept name. Supports fuzzy matching."},
          depth:        %{type: "integer", description: "BFS hops from the matched node (1–3). Default 2.", default: 2, minimum: 1, maximum: 3},
          include_code: %{type: "boolean", description: "Embed actual source lines per node. Eliminates separate Read calls for small slices. Default false.", default: false}
        },
        required: ["search_term"]
      }
    }
  end

  defp tool_schema("find_tests") do
    %{
      name: "find_tests",
      description: """
      Find the specific test functions that exercise a given node, using inbound
      BFS (same as affected_by) filtered to files in test/ or spec/ directories.

      Returns each matching test with its file, line, and a ready-to-run shell
      command. Use this immediately after an edit to get the minimal, high-certainty
      test suite for that change — then run each command via spawn_process and
      monitor with tail_output. Prevents regression blindness: tests for downstream
      callers are included, not just tests for the function you changed directly.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          search_term: %{type: "string", description: "Function or module you just edited."},
          depth:       %{type: "integer", description: "BFS hops to search for callers (1–3). Default 3.", default: 3, minimum: 1, maximum: 3}
        },
        required: ["search_term"]
      }
    }
  end

  defp tool_schema("affected_by") do
    %{
      name: "affected_by",
      description: """
      Find all nodes that would be affected if a given function, module, or class changes.
      Follows inbound edges only — callers, importers, dependents.
      Use before refactoring to understand blast radius and plan safe change order.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          search_term:  %{type: "string",  description: "Node to check impact for."},
          depth:        %{type: "integer", description: "How many hops of callers/importers to include (1–3). Default 2.", default: 2, minimum: 1, maximum: 3},
          include_code: %{type: "boolean", description: "Embed source lines per node. Default false.", default: false}
        },
        required: ["search_term"]
      }
    }
  end

  defp tool_schema("workspace_stats") do
    %{
      name: "workspace_stats",
      description: "Graph topology overview: total nodes/edges, count by type, most-connected modules, watched directories, and number of embedded nodes ready for semantic search. Use at session start to orient before querying.",
      inputSchema: %{type: "object", properties: %{}}
    }
  end

  defp tool_schema("add_content_node") do
    %{
      name: "add_content_node",
      description: """
      Add a non-code knowledge node to the graph and link it to the code that implements it.

      Content nodes capture business knowledge above the code layer:
      - BusinessRule: policies, invariants, constraints ("payments >$10k need dual approval")
      - Copy: UI strings, emails, notifications, marketing text
      - Contract: API specs, data shapes, interface agreements
      - Domain: bounded contexts, ubiquitous language, domain concepts

      Once linked via IMPLEMENTS edges, find_implementations shows every code node
      that must change when the rule changes.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          type:       %{type: "string", description: "Node type.", enum: ["BusinessRule", "Copy", "Contract", "Domain"]},
          name:       %{type: "string", description: "Short, human-readable name (becomes the node ID slug)."},
          content:    %{type: "string", description: "Full description of the rule, copy text, contract, or concept."},
          implements: %{
            type: "array",
            items: %{type: "string"},
            description: "Graph node IDs this content node governs (e.g. 'Function:check_payment_limit'). Use query_code_graph first to find the right IDs."
          }
        },
        required: ["type", "name", "content"]
      }
    }
  end

  defp tool_schema("update_content_node") do
    %{
      name: "update_content_node",
      description: "Update a content node's text and/or IMPLEMENTS links. All fields are optional — only provided fields are changed.",
      inputSchema: %{
        type: "object",
        properties: %{
          id:                %{type: "string", description: "Content node ID (e.g. 'BusinessRule:payment_approval')."},
          name:              %{type: "string", description: "New name."},
          content:           %{type: "string", description: "Updated rule/copy/contract text."},
          add_implements:    %{type: "array", items: %{type: "string"}, description: "Code node IDs to add IMPLEMENTS edges to."},
          remove_implements: %{type: "array", items: %{type: "string"}, description: "Code node IDs to remove IMPLEMENTS edges from."}
        },
        required: ["id"]
      }
    }
  end

  defp tool_schema("delete_content_node") do
    %{
      name: "delete_content_node",
      description: "Remove a content node from the graph and the persistent store.",
      inputSchema: %{
        type: "object",
        properties: %{id: %{type: "string", description: "Content node ID to delete."}},
        required: ["id"]
      }
    }
  end

  defp tool_schema("find_implementations") do
    %{
      name: "find_implementations",
      description: """
      Given a content node, return all code nodes it governs via IMPLEMENTS edges,
      with full metadata (file, line). Use this when a business rule or contract
      changes to find exactly which functions need to be updated.
      """,
      inputSchema: %{
        type: "object",
        properties: %{id: %{type: "string", description: "Content node ID (e.g. 'BusinessRule:payment_approval')."}},
        required: ["id"]
      }
    }
  end

  defp tool_schema("list_content_nodes") do
    %{
      name: "list_content_nodes",
      description: "List all content nodes in the graph. Filter by type to focus on rules, copy, contracts, or domain concepts.",
      inputSchema: %{
        type: "object",
        properties: %{
          type: %{type: "string", description: "Filter by type: BusinessRule, Copy, Contract, or Domain. Omit to list all.", enum: ["BusinessRule", "Copy", "Contract", "Domain"]}
        }
      }
    }
  end

  defp tool_schema("semantic_search") do
    %{
      name: "semantic_search",
      description: """
      Natural-language search over the code graph using vector embeddings.
      Embeds the query, finds the most semantically similar nodes (even if the
      exact name is unknown), then BFS-expands from those seeds into a context
      slice — just like query_code_graph but driven by meaning instead of name.

      Best for: "how does authentication work?", "where is rate limiting handled?",
      "find the payment processing logic" — queries where you don't know the
      exact function or module name.

      Requires an embedding backend to be running (default: Ollama with
      nomic-embed-text). Embeddings are built in the background after indexing,
      so results improve over time. Check embeddings_ready in workspace_stats
      to see coverage.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          query:        %{type: "string",  description: "Natural language description of the code you're looking for."},
          top_k:        %{type: "integer", description: "Number of seed nodes to find via similarity (default 5).", default: 5, minimum: 1, maximum: 20},
          depth:        %{type: "integer", description: "BFS hops from each seed node (1–3, default 2).", default: 2, minimum: 1, maximum: 3},
          include_code: %{type: "boolean", description: "Embed actual source lines per node. Default false.", default: false}
        },
        required: ["query"]
      }
    }
  end

  defp tool_schema("index_directory") do
    %{
      name: "index_directory",
      description: "Index all Elixir and JS/TS source files in a directory. Run once at session start.",
      inputSchema: %{
        type: "object",
        properties: %{path: %{type: "string", description: "Directory to index recursively."}},
        required: ["path"]
      }
    }
  end

  defp tool_schema("index_file") do
    %{
      name: "index_file",
      description: "Index a single source file into the current graph.",
      inputSchema: %{
        type: "object",
        properties: %{path: %{type: "string", description: "Source file path."}},
        required: ["path"]
      }
    }
  end

  defp tool_schema("load_graph") do
    %{
      name: "load_graph",
      description: "Load a pre-compiled graph binary. Much faster than re-indexing at session start.",
      inputSchema: %{
        type: "object",
        properties: %{path: %{type: "string", description: "Path to .bin graph file."}},
        required: ["path"]
      }
    }
  end

  defp tool_schema("save_graph") do
    %{
      name: "save_graph",
      description: "Save the current in-memory graph to a .bin file.",
      inputSchema: %{
        type: "object",
        properties: %{path: %{type: "string", description: "Output .bin file path."}},
        required: ["path"]
      }
    }
  end

  defp tool_schema("spawn_process") do
    %{
      name: "spawn_process",
      description: """
      Start a command and begin capturing its output. The process runs in the
      background across agent turns. Use tail_output to poll for new lines.
      Ideal for: mix test --watch, npm run dev, type checkers, build watchers.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Unique name to identify this process (e.g. \"tests\", \"dev_server\")."},
          cmd:  %{type: "string", description: "Shell command to run (e.g. \"mix test --watch\")."},
          cwd:  %{type: "string", description: "Working directory. Defaults to current directory."}
        },
        required: ["name", "cmd"]
      }
    }
  end

  defp tool_schema("list_processes") do
    %{
      name: "list_processes",
      description: "List all monitored processes with their status and last output line. Use this to get a dashboard view before deciding what to poll.",
      inputSchema: %{type: "object", properties: %{}}
    }
  end

  defp tool_schema("read_output") do
    %{
      name: "read_output",
      description: "Read the last N lines from a named process. Use for an initial snapshot. For ongoing monitoring, prefer tail_output.",
      inputSchema: %{
        type: "object",
        properties: %{
          name:  %{type: "string", description: "Process name."},
          limit: %{type: "integer", description: "Number of lines to return (default 50, max 500).", default: 50}
        },
        required: ["name"]
      }
    }
  end

  defp tool_schema("tail_output") do
    %{
      name: "tail_output",
      description: """
      Return only lines produced since `cursor`. Use the returned `next_cursor`
      in your next call to receive only new output. This is the efficient polling
      primitive for the feedback loop — cost is proportional to new lines only.
      Start with cursor=0 to get all output so far.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          name:   %{type: "string",  description: "Process name."},
          cursor: %{type: "integer", description: "Last line number seen. Use 0 to start from the beginning.", default: 0}
        },
        required: ["name"]
      }
    }
  end

  defp tool_schema("stop_process") do
    %{
      name: "stop_process",
      description: "Stop a monitored process and remove it from the registry.",
      inputSchema: %{
        type: "object",
        properties: %{name: %{type: "string", description: "Process name to stop."}},
        required: ["name"]
      }
    }
  end

  defp tool_schema("record_attempt") do
    %{
      name: "record_attempt",
      description: """
      Record a fix attempt for a named problem BEFORE making each change.
      Returns the attempt count and a guidance message when the count reaches
      thresholds (2: note, 3: warning, 5: stop and reconsider).
      If the problem was previously resolved and has recurred, flags it as
      a regression immediately. Use the returned message to decide whether
      to continue or try a different approach.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          key: %{
            type: "string",
            description: "Free-form identifier for the problem (test name, function name, error description, etc.)"
          },
          diagnostic: %{
            type: "string",
            description: "The error message or test failure output for this attempt. When provided, the ledger fingerprints it — if the same error repeats on consecutive attempts despite different code changes, a targeted warning fires before the standard count thresholds."
          }
        },
        required: ["key"]
      }
    }
  end

  defp tool_schema("resolve_problem") do
    %{
      name: "resolve_problem",
      description: "Mark a problem as resolved after confirming it is fixed. If it recurs later, record_attempt will flag it as a regression rather than a fresh attempt.",
      inputSchema: %{
        type: "object",
        properties: %{
          key: %{type: "string", description: "The problem key to resolve."}
        },
        required: ["key"]
      }
    }
  end

  defp tool_schema("list_problems") do
    %{
      name: "list_problems",
      description: "List all open (unresolved) problems sorted by attempt count. Use this to spot what is stuck and what might be oscillating.",
      inputSchema: %{type: "object", properties: %{}}
    }
  end

  defp tool_schema("reset_ledger") do
    %{
      name: "reset_ledger",
      description: "Clear the entire attempt ledger. Use at the start of a new session or after a major refactor resets the baseline.",
      inputSchema: %{type: "object", properties: %{}}
    }
  end

  defp tool_schema("propose_session_plan") do
    %{
      name: "propose_session_plan",
      description: """
      Propose a restricted session plan for a specific task.
      Claude calls this at the start of a task to declare exactly which tools
      and paths it needs — no more. The user reviews and calls approve_session_plan
      to activate it. The plan can only restrict the static allowlist, never expand it.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          task: %{type: "string", description: "Plain-English description of the task being undertaken."},
          tools: %{
            type: "array",
            items: %{type: "string"},
            description: "Subset of allowed tools needed for this task."
          },
          paths: %{
            type: "array",
            items: %{type: "string"},
            description: "Subset of allowed paths that will be accessed."
          },
          max_depth: %{type: "integer", description: "Max BFS depth needed (1–3).", default: 2}
        },
        required: ["task", "tools", "paths"]
      }
    }
  end

  defp tool_schema("approve_session_plan") do
    %{
      name: "approve_session_plan",
      description: "Activate the current session plan draft. Call after reviewing the propose_session_plan output.",
      inputSchema: %{type: "object", properties: %{}}
    }
  end

  defp tool_schema("watch_directory") do
    %{
      name: "watch_directory",
      description: "Start watching a directory for file changes. The graph updates automatically when files are created, modified, or deleted.",
      inputSchema: %{
        type: "object",
        properties: %{path: %{type: "string", description: "Directory to watch."}},
        required: ["path"]
      }
    }
  end

  defp tool_schema("unwatch_directory") do
    %{
      name: "unwatch_directory",
      description: "Stop watching a directory.",
      inputSchema: %{
        type: "object",
        properties: %{path: %{type: "string", description: "Directory to stop watching."}},
        required: ["path"]
      }
    }
  end

  defp tool_schema("sync_graph") do
    %{
      name: "sync_graph",
      description: "Sync the graph against a directory using the saved manifest — only re-indexes files that changed since the last save. Use this after loading a stale .bin to bring the graph up to date without a full re-index.",
      inputSchema: %{
        type: "object",
        properties: %{path: %{type: "string", description: "Directory to sync against."}},
        required: ["path"]
      }
    }
  end

  defp tool_schema("revoke_session_plan") do
    %{
      name: "revoke_session_plan",
      description: "Clear the active session plan and restore the full static allowlist.",
      inputSchema: %{type: "object", properties: %{}}
    }
  end

  defp tool_schema("cross_project_search") do
    %{
      name: "cross_project_search",
      description: """
      Semantic search across ALL indexed projects stored in Neo4j.
      Embeds the query and finds the most similar nodes by vector similarity,
      regardless of which project they belong to. Each result includes the
      project name, node type/name, file path, line number, and similarity score.

      Use this to find prior solutions: "how did I handle authentication in other projects?",
      "where have I used rate limiting before?", "find similar payment processing logic".

      Requires Neo4j to be running and nodes to have stored embeddings (built during
      index_directory with an embedding backend active).
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          query:   %{type: "string",  description: "Natural language description of what you're looking for."},
          top_k:   %{type: "integer", description: "Number of results to return (default 10).", default: 10, minimum: 1, maximum: 50},
          project: %{type: "string",  description: "Restrict search to a single project slug. Omit to search all projects."}
        },
        required: ["query"]
      }
    }
  end

  defp tool_schema("submit_viewer_diff") do
    %{
      name: "submit_viewer_diff",
      description: """
      Append an AI-authored diff to the DirGraph viewer's diff ledger.
      The viewer polls every 2 seconds — your diff will appear automatically
      with a notification badge. Use this to propose architectural changes,
      add annotation commentary, or respond to user-submitted graph edits.

      Workflow:
      1. User submits a diff via the viewer canvas
      2. You read the current graph state and the user's intent
      3. Call this tool with your proposed additions/removals/annotations
      4. User sees your diff in the viewer and can accept or counter-propose

      Node shape: {id, type, name, file?, line?}
      Edge shape: {source, target, label}
      Annotation shape: {id, body, target_node_id?}

      After this, a "Publish Changes" button appears in the viewer, signalling
      the session is ready for code generation.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          project:       %{type: "string", description: "Project slug (matches the directory under ~/sites/diffs/)."},
          label:         %{type: "string", description: "Short human-readable description of this diff (e.g. \"Extract auth middleware\")."},
          added_nodes:   %{type: "array",  items: %{type: "object"}, description: "New nodes to add. Each must have at minimum {id, type, name}.", default: []},
          removed_nodes: %{type: "array",  items: %{type: "string"}, description: "Node IDs to remove.", default: []},
          added_edges:   %{type: "array",  items: %{type: "object"}, description: "New edges to add. Each must have {source, target, label}.", default: []},
          removed_edges: %{type: "array",  items: %{type: "object"}, description: "Edges to remove. Each must have {source, target, label}.", default: []},
          annotations:   %{type: "array",  items: %{type: "object"}, description: "Commentary nodes. Each must have {id, body} and optionally {target_node_id}.", default: []}
        },
        required: ["project", "label"]
      }
    }
  end

  defp tool_schema("neo4j_health") do
    %{
      name: "neo4j_health",
      description: "Check whether the DirGraph Neo4j container is running and return version info. Run this if any Neo4j-dependent operation fails.",
      inputSchema: %{type: "object", properties: %{}}
    }
  end

  defp tool_schema("neo4j_setup_schema") do
    %{
      name: "neo4j_setup_schema",
      description: "Initialise the DirGraph Neo4j schema: project constraints, AST node/edge indexes, and the vector index for semantic search. Safe to run multiple times (idempotent). Run once after starting a fresh container.",
      inputSchema: %{type: "object", properties: %{}}
    }
  end

  defp tool_schema("export_to_viewer") do
    %{
      name: "export_to_viewer",
      description: """
      Export the current in-memory graph as JSON for the DirGraph visual viewer and
      open it in the system browser. Writes full_ast.json and (if absent) an empty
      diff_ledger.json to ~/sites/diffs/{project}/. Run index_directory first.
      Opens http://localhost:5173/?project={project} — start the viewer with:
        cd viewer && npm run dev
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          project: %{
            type: "string",
            description: "Project slug used as the directory name under ~/sites/diffs/ (e.g. \"dir_graph\")."
          }
        },
        required: ["project"]
      }
    }
  end

  defp tool_schema(name),
    do: %{name: name, description: "Tool: #{name}", inputSchema: %{type: "object", properties: %{}}}

  defp reply(id, result), do: %{jsonrpc: "2.0", id: id, result: result}
end
