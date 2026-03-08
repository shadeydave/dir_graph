defmodule DirGraph.IndexerTest do
  use ExUnit.Case, async: true

  alias DirGraph.Indexer
  alias DirGraph.Graph, as: CG

  @fixture_auth Path.expand("test/fixtures/sample_auth.ex")
  @fixture_user Path.expand("test/fixtures/sample_user.ex")

  # ----------------------------------------------------------------
  # Single-file Elixir indexing
  # ----------------------------------------------------------------

  describe "index_file/2 (Elixir)" do
    test "creates a File node for the indexed path" do
      {graph, _refs} = Indexer.index_file(@fixture_auth)
      vids = Graph.vertices(graph)

      assert Enum.any?(vids, fn v ->
        case CG.get_label(graph, v) do
          %{type: "File"} -> true
          _ -> false
        end
      end)
    end

    test "creates a Module node with correct name" do
      {graph, _refs} = Indexer.index_file(@fixture_auth)

      module = Graph.vertices(graph) |> Enum.find(fn v ->
        case CG.get_label(graph, v) do
          %{type: "Module", name: "SampleAuth"} -> true
          _ -> false
        end
      end)

      assert module != nil
    end

    test "creates Function nodes for public functions" do
      {graph, _refs} = Indexer.index_file(@fixture_auth)

      fn_names =
        Graph.vertices(graph)
        |> Enum.flat_map(fn v ->
          case CG.get_label(graph, v) do
            %{type: "Function", name: n} -> [n]
            _ -> []
          end
        end)

      assert Enum.any?(fn_names, &String.contains?(&1, "login"))
      assert Enum.any?(fn_names, &String.contains?(&1, "verify_token"))
    end

    test "CONTAINS edge connects File to Module" do
      {graph, _refs} = Indexer.index_file(@fixture_auth)

      has_contains =
        Graph.edges(graph)
        |> Enum.any?(fn e -> e.label == "CONTAINS" end)

      assert has_contains
    end

    test "DEFINES edges connect Module to Functions" do
      {graph, _refs} = Indexer.index_file(@fixture_auth)

      defines_count =
        Graph.edges(graph)
        |> Enum.count(fn e -> e.label == "DEFINES" end)

      assert defines_count >= 2
    end

    test "line numbers are recorded on function nodes" do
      {graph, _refs} = Indexer.index_file(@fixture_auth)

      has_lines =
        Graph.vertices(graph)
        |> Enum.any?(fn v ->
          case CG.get_label(graph, v) do
            %{type: "Function", line: l} when is_integer(l) -> true
            _ -> false
          end
        end)

      assert has_lines
    end

    test "returns unresolved refs list for cross-file resolution" do
      {_graph, refs} = Indexer.index_file(@fixture_auth)
      assert is_list(refs)
    end

    test "merges into a provided graph (second param)" do
      {g1, _}  = Indexer.index_file(@fixture_auth)
      {g2, _}  = Indexer.index_file(@fixture_user, g1)

      v1 = Graph.vertices(g1) |> length()
      v2 = Graph.vertices(g2) |> length()

      assert v2 > v1
    end
  end

  # ----------------------------------------------------------------
  # Cross-file reference resolution
  # ----------------------------------------------------------------

  describe "resolve_cross_file_refs/2" do
    test "adds IMPORTS edge between files when alias is resolved" do
      {g1, r1} = Indexer.index_file(@fixture_auth)
      {g2, r2} = Indexer.index_file(@fixture_user, g1)
      all_refs  = r1 ++ r2
      resolved  = Indexer.resolve_cross_file_refs(g2, all_refs)

      import_edges = Graph.edges(resolved) |> Enum.filter(fn e -> e.label == "IMPORTS" end)
      assert length(import_edges) >= 1
    end
  end

  # ----------------------------------------------------------------
  # purge_file/2
  # ----------------------------------------------------------------

  describe "purge_file/2" do
    test "removes all nodes belonging to the file" do
      {graph, _} = Indexer.index_file(@fixture_auth)
      before_count = Graph.vertices(graph) |> length()

      purged = Indexer.purge_file(graph, @fixture_auth)
      after_count = Graph.vertices(purged) |> length()

      assert after_count < before_count
    end

    test "no-op on a path that is not in the graph" do
      {graph, _}  = Indexer.index_file(@fixture_auth)
      purged      = Indexer.purge_file(graph, "/nonexistent/file.ex")

      assert Graph.vertices(purged) == Graph.vertices(graph)
    end
  end

  # ----------------------------------------------------------------
  # collect_files/1
  # ----------------------------------------------------------------

  describe "collect_files/1" do
    test "finds .ex files and skips non-source directories" do
      files = Indexer.collect_files("lib/")
      assert Enum.all?(files, fn f -> Path.extname(f) in ~w(.ex .exs .js .ts .jsx .tsx .py .rb .go .rs) end)
      refute Enum.any?(files, &String.contains?(&1, "/_build/"))
      refute Enum.any?(files, &String.contains?(&1, "/deps/"))
    end
  end

  # ----------------------------------------------------------------
  # save_graph / load_graph (round-trip)
  # ----------------------------------------------------------------

  describe "save_graph/2 + load_graph/1" do
    @tag :tmp_dir
    test "round-trip preserves vertices and manifest", %{tmp_dir: dir} do
      {graph, _} = Indexer.index_file(@fixture_auth)
      bin_path   = Path.join(dir, "test_graph.bin")

      Indexer.save_graph(graph, bin_path)

      {loaded_graph, manifest} = Indexer.load_graph(bin_path)

      assert Graph.vertices(loaded_graph) |> length() == Graph.vertices(graph) |> length()
      assert is_map(manifest)
    end
  end
end
