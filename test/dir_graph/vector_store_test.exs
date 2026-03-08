defmodule DirGraph.VectorStoreTest do
  # NOT async — all tests share the same named ETS table.
  use ExUnit.Case

  alias DirGraph.VectorStore

  setup do
    VectorStore.clear()
    :ok
  end

  # ----------------------------------------------------------------
  # CRUD
  # ----------------------------------------------------------------

  describe "put/2 and size/0" do
    test "stores a vector and increments size" do
      VectorStore.put("node:a", [1.0, 0.0, 0.0])
      assert VectorStore.size() == 1
    end

    test "overwriting the same ID keeps size at 1" do
      VectorStore.put("node:a", [1.0, 0.0])
      VectorStore.put("node:a", [0.0, 1.0])
      assert VectorStore.size() == 1
    end
  end

  describe "delete/1" do
    test "removes a stored entry" do
      VectorStore.put("node:a", [1.0, 0.0])
      VectorStore.delete("node:a")
      assert VectorStore.size() == 0
    end

    test "is a no-op for a missing ID" do
      assert :ok = VectorStore.delete("node:nonexistent")
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      VectorStore.put("node:a", [1.0, 0.0])
      VectorStore.put("node:b", [0.0, 1.0])
      VectorStore.clear()
      assert VectorStore.size() == 0
    end
  end

  # ----------------------------------------------------------------
  # Search + cosine similarity
  # ----------------------------------------------------------------

  describe "search/2 — ordering" do
    test "returns results sorted by descending similarity" do
      VectorStore.put("identical",   [1.0, 0.0, 0.0])
      VectorStore.put("orthogonal",  [0.0, 1.0, 0.0])
      VectorStore.put("opposite",    [-1.0, 0.0, 0.0])

      results = VectorStore.search([1.0, 0.0, 0.0], 3)
      ids = Enum.map(results, fn {id, _} -> id end)

      assert hd(ids)        == "identical"
      assert List.last(ids) == "opposite"
    end

    test "limits results to top_k" do
      for i <- 1..20, do: VectorStore.put("node:#{i}", [i / 20.0, 1.0 - i / 20.0])
      assert length(VectorStore.search([1.0, 0.0], 5)) == 5
    end

    test "returns empty list when store is empty" do
      assert VectorStore.search([1.0, 0.0], 10) == []
    end
  end

  describe "search/2 — cosine similarity correctness" do
    test "identical direction → score ≈ 1.0" do
      VectorStore.put("node:a", [0.6, 0.8])
      [{_, score}] = VectorStore.search([0.6, 0.8], 1)
      assert_in_delta score, 1.0, 0.0001
    end

    test "opposite direction → score ≈ -1.0" do
      VectorStore.put("node:a", [1.0, 0.0])
      [{_, score}] = VectorStore.search([-1.0, 0.0], 1)
      assert_in_delta score, -1.0, 0.0001
    end

    test "orthogonal vectors → score ≈ 0.0" do
      VectorStore.put("node:a", [1.0, 0.0])
      [{_, score}] = VectorStore.search([0.0, 1.0], 1)
      assert_in_delta score, 0.0, 0.0001
    end

    test "unnormalized vectors produce correct cosine" do
      # [3, 4] and [6, 8] point in the same direction → similarity = 1.0
      VectorStore.put("node:a", [3.0, 4.0])
      [{_, score}] = VectorStore.search([6.0, 8.0], 1)
      assert_in_delta score, 1.0, 0.0001
    end

    test "zero vector does not crash (returns 0.0)" do
      VectorStore.put("node:a", [0.0, 0.0])
      [{_, score}] = VectorStore.search([1.0, 0.0], 1)
      assert score == 0.0
    end
  end
end
