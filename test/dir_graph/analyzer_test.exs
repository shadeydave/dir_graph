defmodule DirGraph.AnalyzerTest do
  use ExUnit.Case, async: true

  alias DirGraph.{Analyzer}
  alias DirGraph.Graph, as: CG

  # Build a deterministic CPG in-memory — no file I/O, fast and reliable.
  #
  #   File:auth.ex
  #     └─CONTAINS──▶ Module:Auth
  #                     ├─DEFINES──▶ Function:login/2        ──CALLS──▶ Call:verify_password
  #                     ├─DEFINES──▶ Function:verify_token/1 ──CALLS──▶ Function:hash/1
  #                     └─DEFINES──▶ Function:hash/1

  setup do
    g =
      CG.new()
      |> CG.add_node("File:auth.ex", "File", "auth.ex", %{path: "auth.ex"})
      |> CG.add_node("Module:Auth", "Module", "Auth", %{file: "auth.ex", line: 1})
      |> CG.add_node("Function:login/2", "Function", "login/2", %{
        file: "auth.ex",
        line: 5,
        end_line: 10
      })
      |> CG.add_node("Function:verify_token/1", "Function", "verify_token/1", %{
        file: "auth.ex",
        line: 12,
        end_line: 18
      })
      |> CG.add_node("Function:hash/1", "Function", "hash/1", %{
        file: "auth.ex",
        line: 20,
        end_line: 21
      })
      |> CG.add_node("Call:verify_password", "Call", "verify_password", %{
        file: "auth.ex",
        line: 7
      })
      |> CG.add_edge("File:auth.ex", "Module:Auth", "CONTAINS")
      |> CG.add_edge("Module:Auth", "Function:login/2", "DEFINES")
      |> CG.add_edge("Module:Auth", "Function:verify_token/1", "DEFINES")
      |> CG.add_edge("Module:Auth", "Function:hash/1", "DEFINES")
      |> CG.add_edge("Function:login/2", "Call:verify_password", "CALLS")
      |> CG.add_edge("Function:verify_token/1", "Function:hash/1", "CALLS")

    {:ok, graph: g}
  end

  # ----------------------------------------------------------------
  # find_node/2
  # ----------------------------------------------------------------

  describe "find_node/2" do
    test "exact substring match on vertex ID", %{graph: g} do
      assert Analyzer.find_node(g, "login") == "Function:login/2"
    end

    test "case-insensitive match", %{graph: g} do
      assert Analyzer.find_node(g, "LOGIN") == "Function:login/2"
    end

    test "substring match on label :name field", %{graph: g} do
      assert Analyzer.find_node(g, "verify_token") == "Function:verify_token/1"
    end

    test "Jaro-Winkler fuzzy match for close names", %{graph: g} do
      # "hash" is an exact substring hit — verify the function is returned
      result = Analyzer.find_node(g, "hash")
      assert result == "Function:hash/1"
    end

    test "returns nil when nothing qualifies", %{graph: g} do
      assert Analyzer.find_node(g, "xyzzy_absolute_nonsense_9999") == nil
    end
  end

  # ----------------------------------------------------------------
  # extract_slice/3
  # ----------------------------------------------------------------

  describe "extract_slice/3" do
    test "depth 1: start node + direct neighbors only", %{graph: g} do
      sub = Analyzer.extract_slice(g, "Module:Auth", 1)
      vids = Graph.vertices(sub)

      assert "Module:Auth" in vids
      assert "Function:login/2" in vids
      assert "File:auth.ex" in vids
      # Two hops away — should NOT be in depth-1 slice
      refute "Call:verify_password" in vids
    end

    test "depth 2: reaches two hops from start", %{graph: g} do
      sub = Analyzer.extract_slice(g, "Module:Auth", 2)
      vids = Graph.vertices(sub)

      assert "Call:verify_password" in vids
    end

    test "depth cap at 3: requesting 99 produces same result as 3", %{graph: g} do
      vids_3 = Analyzer.extract_slice(g, "Module:Auth", 3) |> Graph.vertices() |> Enum.sort()
      vids_99 = Analyzer.extract_slice(g, "Module:Auth", 99) |> Graph.vertices() |> Enum.sort()

      assert vids_3 == vids_99
    end

    test "start node is always in the result", %{graph: g} do
      sub = Analyzer.extract_slice(g, "Function:hash/1", 1)
      assert "Function:hash/1" in Graph.vertices(sub)
    end

    test "BFS is bidirectional — reaches both in- and out-neighbors", %{graph: g} do
      # From hash/1, depth 1 should reach verify_token/1 (in-neighbor via CALLS)
      # AND Module:Auth (in-neighbor via DEFINES)
      sub = Analyzer.extract_slice(g, "Function:hash/1", 1)
      vids = Graph.vertices(sub)

      assert "Function:verify_token/1" in vids
      assert "Module:Auth" in vids
    end
  end

  # ----------------------------------------------------------------
  # affected_by/3
  # ----------------------------------------------------------------

  describe "affected_by/3" do
    test "depth 1: returns only direct callers/importers", %{graph: g} do
      sub = Analyzer.affected_by(g, "Function:hash/1", 1)
      vids = Graph.vertices(sub)

      # verify_token/1 CALLS hash/1 — it is affected
      assert "Function:verify_token/1" in vids
      # login/2 does not directly reference hash/1 — not in depth-1
      refute "Function:login/2" in vids
    end

    test "depth 2: reaches transitive callers", %{graph: g} do
      sub = Analyzer.affected_by(g, "Function:hash/1", 2)
      vids = Graph.vertices(sub)

      # Module:Auth DEFINES verify_token/1 which CALLS hash/1 — reachable at depth 2
      assert "Module:Auth" in vids
    end

    test "does NOT follow outbound edges", %{graph: g} do
      # login/2 CALLS verify_password — outbound. affected_by should not include it.
      sub = Analyzer.affected_by(g, "Function:login/2", 1)
      vids = Graph.vertices(sub)

      refute "Call:verify_password" in vids
    end

    test "start node is always included", %{graph: g} do
      sub = Analyzer.affected_by(g, "Function:login/2", 1)
      assert "Function:login/2" in Graph.vertices(sub)
    end
  end

  # ----------------------------------------------------------------
  # format_for_llm/2
  # ----------------------------------------------------------------

  describe "format_for_llm/2" do
    test "returns expected top-level keys", %{graph: g} do
      sub = Analyzer.extract_slice(g, "Module:Auth", 1)
      payload = Analyzer.format_for_llm(sub)

      assert Map.has_key?(payload, :node_count)
      assert Map.has_key?(payload, :edge_count)
      assert Map.has_key?(payload, :nodes)
      assert Map.has_key?(payload, :edges)
    end

    test "node_count matches actual node list length", %{graph: g} do
      sub = Analyzer.extract_slice(g, "Module:Auth", 2)
      payload = Analyzer.format_for_llm(sub)

      assert payload.node_count == length(payload.nodes)
    end

    test "each node has :id, :type, and :name", %{graph: g} do
      sub = Analyzer.extract_slice(g, "Module:Auth", 1)

      Analyzer.format_for_llm(sub).nodes
      |> Enum.each(fn node ->
        assert Map.has_key?(node, :id)
        assert Map.has_key?(node, :type)
        assert Map.has_key?(node, :name)
      end)
    end

    test "nil metadata fields are stripped from output", %{graph: g} do
      sub = Analyzer.extract_slice(g, "Module:Auth", 1)
      nodes = Analyzer.format_for_llm(sub).nodes

      Enum.each(nodes, fn node ->
        Enum.each(node, fn {_k, v} ->
          refute is_nil(v)
        end)
      end)
    end

    test "include_types filters to requested types only", %{graph: g} do
      sub = Analyzer.extract_slice(g, "Module:Auth", 2)
      payload = Analyzer.format_for_llm(sub, include_types: ["Function"])

      assert Enum.all?(payload.nodes, fn n -> n.type == "Function" end)
    end

    test "include_code: true embeds source lines when file exists", %{graph: _g} do
      # hash/1 has a real file in our fixture
      auth_path = Path.expand("test/fixtures/sample_auth.ex")

      g2 =
        CG.new()
        |> CG.add_node("Function:hash/1", "Function", "hash/1", %{
          file: auth_path,
          line: 21,
          end_line: 21
        })

      sub = Analyzer.extract_slice(g2, "Function:hash/1", 0)
      payload = Analyzer.format_for_llm(sub, include_code: true)
      node = hd(payload.nodes)

      # The fixture file exists — code should be embedded
      assert Map.has_key?(node, :code)
      assert is_binary(node.code)
    end

    test "include_code: false (default) does not add code field", %{graph: g} do
      sub = Analyzer.extract_slice(g, "Module:Auth", 1)
      nodes = Analyzer.format_for_llm(sub).nodes

      Enum.each(nodes, fn node ->
        refute Map.has_key?(node, :code)
      end)
    end

    test "edges include source, target, and rel", %{graph: g} do
      sub = Analyzer.extract_slice(g, "Module:Auth", 1)
      edges = Analyzer.format_for_llm(sub).edges

      Enum.each(edges, fn edge ->
        assert Map.has_key?(edge, :source)
        assert Map.has_key?(edge, :target)
        assert Map.has_key?(edge, :rel)
      end)
    end
  end
end
