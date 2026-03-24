defmodule DirGraph.Indexer do
  require Logger

  @moduledoc """
  Builds a Code Property Graph (CPG) from source files.

  ## Elixir (.ex / .exs)
  Uses `Code.string_to_quoted/1` — the real Elixir parser — to walk the AST and
  extract: modules, functions (public + private), aliases, imports, uses, requires,
  and remote function calls (CALLS edges).

  ## JavaScript, TypeScript, Python, Ruby, Go, Rust (.js .ts .jsx .tsx .py .rb .go .rs)
  Delegates to `DirGraph.LSP.Indexer`, which starts the appropriate language server
  (configured in `.dir_graph/lsp_servers.json`), requests `textDocument/documentSymbol`,
  and maps the hierarchical symbol tree to graph nodes and edges via
  `DirGraph.LSP.SymbolMapper`. Adding a new language requires only a server entry in
  the config — no parser code changes.

  ## Cross-file resolution
  After all files are indexed, unresolved references (Elixir alias/use/import/require,
  JS relative imports) are resolved into IMPORTS edges between File nodes.

  ## Graph model
  Every vertex is a STRING ID. Metadata (type, name, line, file, …) lives in the
  libgraph vertex label. This keeps edges consistent with vertex keys.

    File:"lib/auth.ex"
      └─CONTAINS──▶ Module:"MyApp.Auth"
                       └─DEFINES──▶ Function:"login/2:L45:lib/auth.ex"
                                       └─CALLS──▶ Call:"Repo.get/2:L48:lib/auth.ex"
    File:"lib/auth.ex" ──IMPORTS──▶ File:"lib/user.ex"
  """

  alias DirGraph.Graph, as: CG

  @elixir_extensions ~w(.ex .exs)
  @lsp_extensions ~w(.js .jsx .ts .tsx .py .rb .go .rs)
  @supported_extensions @elixir_extensions ++ @lsp_extensions

  # ================================================================
  # Public API
  # ================================================================

  @doc """
  Indexes a single source file, merging results into `graph` (defaults to empty).
  Returns `{updated_graph, refs}` where `refs` is a list of unresolved cross-file
  references to be resolved later by `resolve_cross_file_refs/2`.
  """
  def index_file(file_path, graph \\ CG.new()) do
    ext = Path.extname(file_path)

    cond do
      ext in @elixir_extensions -> index_elixir_file(file_path, graph)
      ext in @lsp_extensions    -> DirGraph.LSP.Indexer.index_file(file_path, graph)
      true ->
        Logger.warning("Skipping unsupported file type: #{file_path}")
        {graph, []}
    end
  end

  @doc """
  Recursively indexes all supported source files under `dir_path`.
  Skips node_modules, _build, deps, .git, dist.
  Respects `.dir_graphignore` in the indexed directory (one path fragment per line).
  After indexing, runs a cross-file reference resolution pass that adds IMPORTS edges
  between File nodes.
  Returns the fully-linked graph.
  """
  def index_directory(dir_path) do
    dir_path |> collect_files() |> index_file_list()
  end

  @doc """
  Returns all supported source files under `dir_path`, skipping generated/vendor dirs.
  Public so `DirGraph.Server` can use it for startup sync without re-indexing.
  """
  def collect_files(dir_path) do
    ignore_fragments = load_ignore_fragments(dir_path)

    @supported_extensions
    |> Enum.flat_map(fn ext ->
      Path.wildcard(Path.join([dir_path, "**", "*#{ext}"]))
    end)
    |> Enum.reject(fn path ->
      String.contains?(path, "/node_modules/") or
        String.contains?(path, "/_build/") or
        String.contains?(path, "/deps/") or
        String.contains?(path, "/.git/") or
        String.contains?(path, "/dist/") or
        Enum.any?(ignore_fragments, &String.contains?(path, &1))
    end)
    |> Enum.uniq()
  end

  # Reads `.dir_graphignore` from `dir_path` and returns a list of path fragments to exclude.
  # Lines starting with `#` and blank lines are ignored.
  defp load_ignore_fragments(dir_path) do
    ignore_path = Path.join(dir_path, ".dir_graphignore")

    case File.read(ignore_path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))

      {:error, _} ->
        []
    end
  end

  @doc """
  Indexes a list of files into a new graph (or merges into `graph` if supplied).
  Splits Elixir files (AST) from LSP-backed files (batched by language).
  Returns the fully cross-file-resolved graph.
  """
  def index_file_list(files, graph \\ CG.new()) do
    {elixir_files, lsp_files} =
      Enum.split_with(files, &(Path.extname(&1) in @elixir_extensions))

    {graph, elixir_refs} =
      Enum.reduce(elixir_files, {graph, []}, fn file_path, {acc_graph, acc_refs} ->
        try do
          {new_graph, refs} = index_elixir_file(file_path, acc_graph)
          {new_graph, acc_refs ++ refs}
        rescue
          e ->
            Logger.warning("Failed to parse #{file_path}: #{Exception.message(e)}")
            {acc_graph, acc_refs}
        end
      end)

    {graph, lsp_refs} = DirGraph.LSP.Indexer.index_files(lsp_files, graph)

    resolve_cross_file_refs(graph, elixir_refs ++ lsp_refs)
  end

  @doc "Resolves cross-file references collected during indexing into IMPORTS edges."
  def resolve_cross_file_refs(graph, refs) do
    module_to_file = build_module_to_file_map(graph)
    file_to_node = build_file_to_node_map(graph)

    Enum.reduce(refs, graph, fn ref, acc ->
      case ref do
        {:alias, module_name, from_file, _line} ->
          resolve_elixir_ref(acc, module_name, from_file, "IMPORTS", module_to_file, file_to_node)

        {:use, module_name, from_file, _line} ->
          resolve_elixir_ref(acc, module_name, from_file, "USES", module_to_file, file_to_node)

        {:import, module_name, from_file, _line} ->
          resolve_elixir_ref(acc, module_name, from_file, "IMPORTS", module_to_file, file_to_node)

        {:require, module_name, from_file, _line} ->
          resolve_elixir_ref(acc, module_name, from_file, "REQUIRES", module_to_file, file_to_node)

        {:js_import, import_path, from_file, _line} ->
          resolve_js_ref(acc, import_path, from_file, file_to_node)

        {:py_import, import_path, from_file, _line} ->
          resolve_py_ref(acc, import_path, from_file, file_to_node)
      end
    end)
  end

  @doc """
  Removes all nodes (and their edges) that belong to `file_path` from the graph.
  Call this before re-indexing a changed file to prevent stale nodes accumulating.

  Matches on both `:file` (functions, modules, calls) and `:path` (the File node itself).
  """
  def purge_file(graph, file_path) do
    to_remove =
      Graph.vertices(graph)
      |> Enum.filter(fn vid ->
        case CG.get_label(graph, vid) do
          %{file: ^file_path} -> true
          %{path: ^file_path} -> true
          _ -> false
        end
      end)

    Enum.reduce(to_remove, graph, &Graph.delete_vertex(&2, &1))
  end

  @doc "Serialize the graph to a binary file, embedding a file-metadata manifest for delta sync."
  def save_graph(graph, path) do
    manifest = DirGraph.Manifest.from_graph(graph)
    File.write!(path, :erlang.term_to_binary({graph, manifest}))
  end

  @doc """
  Load a graph from a binary file. Returns `{graph, manifest}`.
  Handles legacy binaries (graph only, no manifest) by returning an empty manifest.
  """
  def load_graph(path) do
    case path |> File.read!() |> :erlang.binary_to_term() do
      {graph, manifest} when is_map(manifest) -> {graph, manifest}
      graph -> {graph, %{}}
    end
  end

  # ================================================================
  # Elixir file entry point
  # ================================================================

  defp index_elixir_file(file_path, graph) do
    source = File.read!(file_path)
    file_node_id = "File:#{file_path}"
    file_name = Path.basename(file_path)
    graph = CG.add_node(graph, file_node_id, "File", file_name, %{path: file_path})

    state = %{
      graph: graph,
      file_path: file_path,
      file_node_id: file_node_id,
      scope_stack: [],
      refs: []
    }

    result = index_elixir(source, state)
    {result.graph, result.refs}
  end

  # ================================================================
  # Elixir AST Walker
  # ================================================================

  defp index_elixir(source, state) do
    case Code.string_to_quoted(source, line: 1) do
      {:ok, ast} ->
        walk(ast, state)

      {:error, {meta, message, token}} ->
        line = Keyword.get(meta, :line, 0)

        Logger.warning("Parse error in #{state.file_path} at line #{line}: #{message}#{token}")

        state
    end
  end

  # --- Elixir AST walk/2 ---
  # Each clause handles a specific Elixir construct, then either recurses into
  # children (with updated scope) or falls through to the generic handler.

  # Block of statements
  defp walk({:__block__, _meta, stmts}, state) do
    Enum.reduce(stmts, state, &walk/2)
  end

  # defmodule MyApp.Something do ... end
  defp walk({:defmodule, meta, [{:__aliases__, _, parts}, [do: body]]}, state) do
    module_name = parts |> Enum.map(&to_string/1) |> Enum.join(".")
    line = Keyword.get(meta, :line, 0)
    node_id = "Module:#{module_name}"

    graph =
      CG.add_node(state.graph, node_id, "Module", module_name, %{
        line: line,
        file: state.file_path
      })

    graph = CG.add_edge(graph, state.file_node_id, node_id, "CONTAINS")

    new_state = %{state | graph: graph, scope_stack: [{:module, node_id} | state.scope_stack]}
    result = walk(body, new_state)
    %{result | scope_stack: state.scope_stack}
  end

  # def / defp / defmacro / defmacrop
  defp walk({kind, meta, [{name, _, args}, [do: body]]}, state)
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    line = Keyword.get(meta, :line, 0)
    visibility = if kind in [:def, :defmacro], do: :public, else: :private
    parent_id = current_scope(state.scope_stack)

    func_label = "#{name}/#{arity}"
    node_id = "Function:#{func_label}:L#{line}:#{state.file_path}"

    graph =
      CG.add_node(state.graph, node_id, "Function", to_string(name), %{
        line: line,
        arity: arity,
        visibility: visibility,
        file: state.file_path,
        label: func_label
      })

    graph =
      if parent_id do
        CG.add_edge(graph, parent_id, node_id, "DEFINES")
      else
        CG.add_edge(graph, state.file_node_id, node_id, "CONTAINS")
      end

    new_state = %{
      state
      | graph: graph,
        scope_stack: [{:function, node_id} | state.scope_stack]
    }

    result = walk(body, new_state)
    %{result | scope_stack: state.scope_stack}
  end

  # alias MyApp.Module
  defp walk({:alias, meta, [{:__aliases__, _, parts} | _]}, state) do
    module_name = parts |> Enum.map(&to_string/1) |> Enum.join(".")
    line = Keyword.get(meta, :line, 0)
    %{state | refs: [{:alias, module_name, state.file_path, line} | state.refs]}
  end

  # use GenServer / use MyApp.Macro
  defp walk({:use, meta, [{:__aliases__, _, parts} | _]}, state) do
    module_name = parts |> Enum.map(&to_string/1) |> Enum.join(".")
    line = Keyword.get(meta, :line, 0)
    %{state | refs: [{:use, module_name, state.file_path, line} | state.refs]}
  end

  # import MyApp.Module
  defp walk({:import, meta, [{:__aliases__, _, parts} | _]}, state) do
    module_name = parts |> Enum.map(&to_string/1) |> Enum.join(".")
    line = Keyword.get(meta, :line, 0)
    %{state | refs: [{:import, module_name, state.file_path, line} | state.refs]}
  end

  # require MyApp.Module
  defp walk({:require, meta, [{:__aliases__, _, parts} | _]}, state) do
    module_name = parts |> Enum.map(&to_string/1) |> Enum.join(".")
    line = Keyword.get(meta, :line, 0)
    %{state | refs: [{:require, module_name, state.file_path, line} | state.refs]}
  end

  # Remote call: MyModule.function(args)
  # Extracts a CALLS edge from the current function scope to the call target.
  defp walk(
         {{:., meta, [{:__aliases__, _, parts}, func_name]}, _, args},
         state
       )
       when is_atom(func_name) do
    state =
      case current_scope(state.scope_stack) do
        nil ->
          state

        caller_id ->
          line = Keyword.get(meta, :line, 0)
          module_name = parts |> Enum.map(&to_string/1) |> Enum.join(".")
          call_target = "#{module_name}.#{func_name}"
          call_node_id = "Call:#{call_target}:L#{line}:#{state.file_path}"

          graph =
            CG.add_node(state.graph, call_node_id, "Call", call_target, %{
              line: line,
              file: state.file_path
            })

          graph = CG.add_edge(graph, caller_id, call_node_id, "CALLS")
          %{state | graph: graph}
      end

    # Continue walking into the call arguments for nested calls
    Enum.reduce(args || [], state, &walk/2)
  end

  # Lists (argument lists, block contents in keyword form, etc.)
  defp walk(list, state) when is_list(list) do
    Enum.reduce(list, state, &walk/2)
  end

  # Generic 3-tuple AST node — walk its children
  defp walk({_form, _meta, children}, state) when is_list(children) do
    Enum.reduce(children, state, &walk/2)
  end

  # 2-tuple (keyword pairs like `{:do, body}`)
  defp walk({_k, v}, state) do
    walk(v, state)
  end

  # Leaf: atom, integer, string, nil, boolean, etc.
  defp walk(_leaf, state), do: state

  defp current_scope([{_kind, id} | _]), do: id
  defp current_scope([]), do: nil

  # ================================================================
  # Cross-file Reference Resolution
  # ================================================================

  defp build_module_to_file_map(graph) do
    graph
    |> Graph.vertices()
    |> Enum.flat_map(fn vid ->
      case CG.get_label(graph, vid) do
        %{type: "Module", file: file} -> [{vid |> module_name_from_id(), file}]
        _ -> []
      end
    end)
    |> Enum.into(%{})
  end

  defp module_name_from_id("Module:" <> rest), do: rest
  defp module_name_from_id(id), do: id

  defp build_file_to_node_map(graph) do
    graph
    |> Graph.vertices()
    |> Enum.flat_map(fn vid ->
      case CG.get_label(graph, vid) do
        %{type: "File", path: path} -> [{path, vid}]
        _ -> []
      end
    end)
    |> Enum.into(%{})
  end

  defp resolve_elixir_ref(graph, module_name, from_file, edge_label, module_to_file, file_to_node) do
    with target_file when not is_nil(target_file) <- Map.get(module_to_file, module_name),
         true <- target_file != from_file,
         from_node when not is_nil(from_node) <- Map.get(file_to_node, from_file),
         to_node when not is_nil(to_node) <- Map.get(file_to_node, target_file) do
      CG.add_edge(graph, from_node, to_node, edge_label)
    else
      _ -> graph
    end
  end

  defp resolve_py_ref(graph, import_path, from_file, file_to_node) do
    # Python relative imports arrive as e.g. "./utils" or "../models/user".
    # Try the path + ".py" extension, then + "/__init__.py" for packages.
    if String.starts_with?(import_path, ".") or not String.contains?(import_path, "/") do
      from_dir = Path.dirname(from_file)
      resolved_base = Path.expand(Path.join(from_dir, import_path))

      target_file =
        ["#{resolved_base}.py", Path.join(resolved_base, "__init__.py")]
        |> Enum.find(&Map.has_key?(file_to_node, &1))

      with target_file when not is_nil(target_file) <- target_file,
           from_node when not is_nil(from_node) <- Map.get(file_to_node, from_file),
           to_node when not is_nil(to_node) <- Map.get(file_to_node, target_file) do
        CG.add_edge(graph, from_node, to_node, "IMPORTS")
      else
        _ -> graph
      end
    else
      graph
    end
  end

  defp resolve_js_ref(graph, import_path, from_file, file_to_node) do
    # Only resolve relative paths — npm package names are external
    if String.starts_with?(import_path, ".") do
      from_dir = Path.dirname(from_file)
      resolved_base = Path.expand(Path.join(from_dir, import_path))

      # Try appending common extensions, then index file variants
      target_file =
        Enum.find_value(~w(.ts .tsx .js .jsx), fn ext ->
          candidate = resolved_base <> ext
          if Map.has_key?(file_to_node, candidate), do: candidate
        end) ||
          Enum.find_value(~w(index.ts index.tsx index.js index.jsx), fn idx ->
            candidate = Path.join(resolved_base, idx)
            if Map.has_key?(file_to_node, candidate), do: candidate
          end)

      with target_file when not is_nil(target_file) <- target_file,
           from_node when not is_nil(from_node) <- Map.get(file_to_node, from_file),
           to_node when not is_nil(to_node) <- Map.get(file_to_node, target_file) do
        CG.add_edge(graph, from_node, to_node, "IMPORTS")
      else
        _ -> graph
      end
    else
      graph
    end
  end
end
