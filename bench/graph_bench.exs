##
## DirGraph — Graph Indexing & Slice Benchmarks
##
## Answers the core proof-of-concept question:
##   "How fast is a CPG query vs reading whole files?
##    And how much smaller is the slice output than the raw source?"
##
## Run with:
##   mix run bench/graph_bench.exs
##

Application.ensure_all_started(:dir_graph)

alias DirGraph.{Indexer, Analyzer}
alias DirGraph.Graph, as: CG

# ================================================================
# 1. Build a synthetic graph of N nodes for realistic BFS timing
# ================================================================

IO.puts("\n=== Building synthetic graph (500 functions, 5 modules) ===\n")

build_graph = fn node_count ->
  base = CG.new()

  # 5 modules, each with node_count/5 functions, fully interconnected
  per_module = div(node_count, 5)

  Enum.reduce(1..5, base, fn mod_i, g ->
    mod_id = "Module:Mod#{mod_i}"
    g = CG.add_node(g, mod_id, "Module", "Mod#{mod_i}", %{file: "lib/mod#{mod_i}.ex", line: 1})

    Enum.reduce(1..per_module, g, fn fn_i, g2 ->
      fn_id   = "Function:mod#{mod_i}_fn#{fn_i}"
      call_id = "Call:mod#{mod_i}_fn#{fn_i}_call"

      g2
      |> CG.add_node(fn_id,   "Function", "fn#{fn_i}",       %{file: "lib/mod#{mod_i}.ex", line: fn_i * 3, end_line: fn_i * 3 + 2})
      |> CG.add_node(call_id, "Call",     "call_#{fn_i}",    %{file: "lib/mod#{mod_i}.ex", line: fn_i * 3 + 1})
      |> CG.add_edge(mod_id,  fn_id,   "DEFINES")
      |> CG.add_edge(fn_id,   call_id, "CALLS")
      # Cross-module call: fn1 of each module calls fn1 of next module
      |> then(fn g3 ->
        if fn_i == 1 and mod_i < 5 do
          next_fn = "Function:mod#{mod_i + 1}_fn1"
          CG.add_edge(g3, fn_id, next_fn, "CALLS")
        else
          g3
        end
      end)
    end)
  end)
end

graph_500  = build_graph.(500)
graph_2000 = build_graph.(2000)

total_nodes_500  = Graph.vertices(graph_500)  |> length()
total_nodes_2000 = Graph.vertices(graph_2000) |> length()
IO.puts("Synthetic graph (500 fns):  #{total_nodes_500} nodes, #{Graph.edges(graph_500) |> length()} edges")
IO.puts("Synthetic graph (2000 fns): #{total_nodes_2000} nodes, #{Graph.edges(graph_2000) |> length()} edges")

# ================================================================
# 2. Token savings proof of concept
#    Compare slice output size vs full raw source read
# ================================================================

IO.puts("\n=== Token Savings: Slice vs Full File Read ===\n")

fixture_dir = Path.expand("test/fixtures")

if File.dir?(fixture_dir) do
  {graph, refs} = Indexer.index_file(Path.join(fixture_dir, "sample_auth.ex"))
  {graph, refs2} = Indexer.index_file(Path.join(fixture_dir, "sample_user.ex"), graph)
  all_refs = refs ++ refs2
  graph = Indexer.resolve_cross_file_refs(graph, all_refs)

  # Full raw file sizes
  auth_raw  = File.read!(Path.join(fixture_dir, "sample_auth.ex"))
  user_raw  = File.read!(Path.join(fixture_dir, "sample_user.ex"))
  total_raw = byte_size(auth_raw) + byte_size(user_raw)

  # Slice around "login" at depth 2
  case Analyzer.find_node(graph, "login") do
    nil ->
      IO.puts("(No 'login' node found in fixture — skipping token savings demo)")

    vid ->
      sub     = Analyzer.extract_slice(graph, vid, 2)
      payload = Analyzer.format_for_llm(sub, include_code: true)
      slice_json = Jason.encode!(payload, pretty: true)

      slice_bytes  = byte_size(slice_json)
      savings_pct  = Float.round((1 - slice_bytes / total_raw) * 100, 1)

      IO.puts("Raw source files:     #{total_raw} bytes  (~#{div(total_raw, 4)} tokens)")
      IO.puts("Slice (depth 2):      #{slice_bytes} bytes  (~#{div(slice_bytes, 4)} tokens)")
      IO.puts("Nodes in slice:       #{payload.node_count} / #{Graph.vertices(graph) |> length()} total")
      IO.puts("Token savings:        ~#{savings_pct}% fewer tokens\n")

      IO.puts("Slice preview (node names):")
      Enum.each(payload.nodes, fn n ->
        loc = if n[:file], do: " (#{Path.basename(n.file)}:#{n[:line]})", else: ""
        IO.puts("  [#{n.type}] #{n.name}#{loc}")
      end)
  end
else
  IO.puts("(Fixture files not found — run from project root)")
end

# ================================================================
# 3. BFS slice benchmarks across depths and graph sizes
# ================================================================

IO.puts("\n=== Benchmarking BFS Slice Extraction ===\n")

start_node_500  = "Function:mod1_fn1"
start_node_2000 = "Function:mod1_fn1"

Benchee.run(
  %{
    "extract_slice depth=1 (500 nodes)"  => fn -> Analyzer.extract_slice(graph_500,  start_node_500,  1) end,
    "extract_slice depth=2 (500 nodes)"  => fn -> Analyzer.extract_slice(graph_500,  start_node_500,  2) end,
    "extract_slice depth=3 (500 nodes)"  => fn -> Analyzer.extract_slice(graph_500,  start_node_500,  3) end,
    "extract_slice depth=2 (2000 nodes)" => fn -> Analyzer.extract_slice(graph_2000, start_node_2000, 2) end,
    "affected_by   depth=2 (500 nodes)"  => fn -> Analyzer.affected_by(graph_500,    start_node_500,  2) end,
    "find_node exact  (500 nodes)"       => fn -> Analyzer.find_node(graph_500,  "fn1") end,
    "find_node exact (2000 nodes)"       => fn -> Analyzer.find_node(graph_2000, "fn1") end,
    "find_node fuzzy  (500 nodes)"       => fn -> Analyzer.find_node(graph_500,  "funcn1_approx") end,
  },
  time:            3,
  warmup:          1,
  memory_time:     1,
  formatters: [
    {Benchee.Formatters.Console, comparison: true, extended_statistics: false}
  ]
)

# ================================================================
# 4. format_for_llm overhead
# ================================================================

IO.puts("\n=== format_for_llm output sizing ===\n")

sub_d1 = Analyzer.extract_slice(graph_500, start_node_500, 1)
sub_d2 = Analyzer.extract_slice(graph_500, start_node_500, 2)
sub_d3 = Analyzer.extract_slice(graph_500, start_node_500, 3)

for {label, sub} <- [{"depth=1", sub_d1}, {"depth=2", sub_d2}, {"depth=3", sub_d3}] do
  payload = Analyzer.format_for_llm(sub)
  json    = Jason.encode!(payload)
  IO.puts("  #{label}: #{payload.node_count} nodes, #{payload.edge_count} edges, #{byte_size(json)} bytes JSON (~#{div(byte_size(json), 4)} tokens)")
end

IO.puts("\nDone.\n")
