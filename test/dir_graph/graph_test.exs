defmodule DirGraph.GraphTest do
  use ExUnit.Case, async: true

  alias DirGraph.Graph, as: CG

  describe "new/0" do
    test "produces an empty graph" do
      g = CG.new()
      assert Graph.vertices(g) == []
      assert Graph.edges(g) == []
    end
  end

  describe "add_node/5" do
    test "stores type, name, and attributes as a vertex label" do
      g = CG.new() |> CG.add_node("fn:login", "Function", "login", %{line: 10, file: "auth.ex"})

      label = CG.get_label(g, "fn:login")
      assert label.type  == "Function"
      assert label.name  == "login"
      assert label.line  == 10
      assert label.file  == "auth.ex"
      assert label.id    == "fn:login"
    end

    test "is a no-op when vertex ID already exists (libgraph semantics)" do
      g =
        CG.new()
        |> CG.add_node("fn:login", "Function", "original", %{line: 1})
        |> CG.add_node("fn:login", "Function", "overwrite_attempt", %{line: 99})

      assert CG.get_label(g, "fn:login").name == "original"
    end

    test "id field is always injected into returned label" do
      g = CG.new() |> CG.add_node("mod:Auth", "Module", "Auth", %{})
      assert CG.get_label(g, "mod:Auth").id == "mod:Auth"
    end
  end

  describe "get_label/2" do
    test "returns nil for a non-existent vertex" do
      g = CG.new()
      assert CG.get_label(g, "does_not_exist") == nil
    end

    test "returns nil for a vertex added without a label" do
      g = Graph.add_vertex(CG.new(), "bare_vertex")
      assert CG.get_label(g, "bare_vertex") == nil
    end
  end

  describe "add_edge/4" do
    test "creates a directed labeled edge between two vertex IDs" do
      g =
        CG.new()
        |> CG.add_node("mod:Auth", "Module", "Auth", %{})
        |> CG.add_node("fn:login", "Function", "login", %{})
        |> CG.add_edge("mod:Auth", "fn:login", "DEFINES")

      [edge] = Graph.edges(g)
      assert edge.v1    == "mod:Auth"
      assert edge.v2    == "fn:login"
      assert edge.label == "DEFINES"
    end

    test "multiple edge types can exist between the same nodes" do
      g =
        CG.new()
        |> CG.add_node("a", "Node", "a", %{})
        |> CG.add_node("b", "Node", "b", %{})
        |> CG.add_edge("a", "b", "CALLS")
        |> CG.add_edge("a", "b", "IMPORTS")

      labels = Graph.edges(g) |> Enum.map(& &1.label)
      assert "CALLS"   in labels
      assert "IMPORTS" in labels
    end
  end

  describe "all_nodes/1" do
    test "returns only labeled vertices with :id injected" do
      g =
        CG.new()
        |> CG.add_node("fn:a", "Function", "a", %{})
        |> CG.add_node("fn:b", "Function", "b", %{})

      nodes = CG.all_nodes(g)
      assert length(nodes) == 2
      assert Enum.all?(nodes, &Map.has_key?(&1, :id))
    end

    test "unlabeled vertices are excluded" do
      g = Graph.add_vertex(CG.new(), "bare")
      assert CG.all_nodes(g) == []
    end
  end
end
