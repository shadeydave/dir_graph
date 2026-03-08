defmodule DirGraph.ContentStoreTest do
  # NOT async — tests share the filesystem store path.
  use ExUnit.Case

  alias DirGraph.ContentStore

  setup do
    File.rm(ContentStore.store_path())
    on_exit(fn -> File.rm(ContentStore.store_path()) end)
    :ok
  end

  # ----------------------------------------------------------------
  # make_id/2
  # ----------------------------------------------------------------

  describe "make_id/2" do
    test "slugifies name and prefixes with type" do
      assert ContentStore.make_id("BusinessRule", "Payment Approval") == "BusinessRule:payment_approval"
    end

    test "collapses special characters to underscores" do
      assert ContentStore.make_id("Copy", "Sign-Up Email #1") == "Copy:sign_up_email_1"
    end

    test "trims leading/trailing underscores" do
      assert ContentStore.make_id("Domain", "  bounded context  ") == "Domain:bounded_context"
    end
  end

  # ----------------------------------------------------------------
  # put/1 + get/1 + all/0
  # ----------------------------------------------------------------

  describe "put/1" do
    test "creates a new node and persists it" do
      node = sample_node("BusinessRule:test_rule")
      assert {:ok, ^node} = ContentStore.put(node)
      assert ContentStore.get("BusinessRule:test_rule") == node
    end

    test "overwrites an existing node with the same ID" do
      node    = sample_node("BusinessRule:test_rule")
      updated = Map.put(node, "content", "Updated content")

      ContentStore.put(node)
      {:ok, saved} = ContentStore.put(updated)

      assert saved["content"] == "Updated content"
      assert ContentStore.get("BusinessRule:test_rule")["content"] == "Updated content"
    end

    test "multiple nodes coexist in the store" do
      ContentStore.put(sample_node("BusinessRule:rule_a"))
      ContentStore.put(sample_node("Copy:copy_b"))

      all = ContentStore.all()
      assert length(all) == 2
    end
  end

  describe "get/1" do
    test "returns nil when no node with that ID exists" do
      assert ContentStore.get("BusinessRule:nonexistent") == nil
    end
  end

  describe "all/0" do
    test "returns empty list when store is empty" do
      assert ContentStore.all() == []
    end

    test "returns all stored nodes" do
      ContentStore.put(sample_node("BusinessRule:rule_a"))
      ContentStore.put(sample_node("Contract:contract_b"))

      assert length(ContentStore.all()) == 2
    end
  end

  # ----------------------------------------------------------------
  # delete/1
  # ----------------------------------------------------------------

  describe "delete/1" do
    test "removes the node from the store" do
      ContentStore.put(sample_node("BusinessRule:to_delete"))
      ContentStore.delete("BusinessRule:to_delete")

      assert ContentStore.get("BusinessRule:to_delete") == nil
    end

    test "is idempotent — no error if ID does not exist" do
      assert :ok = ContentStore.delete("BusinessRule:ghost")
    end

    test "does not affect other nodes" do
      ContentStore.put(sample_node("BusinessRule:keep"))
      ContentStore.put(sample_node("BusinessRule:remove"))

      ContentStore.delete("BusinessRule:remove")

      assert ContentStore.get("BusinessRule:keep") != nil
      assert length(ContentStore.all()) == 1
    end
  end

  # ----------------------------------------------------------------
  # add_link/2 + remove_link/2
  # ----------------------------------------------------------------

  describe "add_link/2" do
    test "adds a code node ID to the implements list" do
      ContentStore.put(sample_node("BusinessRule:linked"))
      {:ok, updated} = ContentStore.add_link("BusinessRule:linked", "Function:check_limit")

      assert "Function:check_limit" in updated["implements"]
    end

    test "is idempotent — duplicate links are not stored" do
      ContentStore.put(sample_node("BusinessRule:linked"))
      ContentStore.add_link("BusinessRule:linked", "Function:check_limit")
      {:ok, updated} = ContentStore.add_link("BusinessRule:linked", "Function:check_limit")

      assert Enum.count(updated["implements"], &(&1 == "Function:check_limit")) == 1
    end

    test "returns error for unknown node ID" do
      assert {:error, _msg} = ContentStore.add_link("BusinessRule:nonexistent", "Function:x")
    end
  end

  describe "remove_link/2" do
    test "removes the code node ID from implements" do
      node = sample_node("BusinessRule:linked", implements: ["Function:a", "Function:b"])
      ContentStore.put(node)

      {:ok, updated} = ContentStore.remove_link("BusinessRule:linked", "Function:a")

      refute "Function:a" in updated["implements"]
      assert "Function:b" in updated["implements"]
    end

    test "returns error for unknown content node" do
      assert {:error, _msg} = ContentStore.remove_link("BusinessRule:ghost", "Function:x")
    end
  end

  # ----------------------------------------------------------------
  # Persistence across reads
  # ----------------------------------------------------------------

  describe "persistence" do
    test "nodes survive a process boundary (re-read from disk)" do
      ContentStore.put(sample_node("Domain:persisted"))

      # Simulate a fresh read — ContentStore.all() reads from disk each time
      all = ContentStore.all()
      assert Enum.any?(all, fn n -> n["id"] == "Domain:persisted" end)
    end
  end

  # ----------------------------------------------------------------
  # valid_types/0
  # ----------------------------------------------------------------

  describe "valid_types/0" do
    test "includes the four canonical types" do
      types = ContentStore.valid_types()
      assert "BusinessRule" in types
      assert "Copy"         in types
      assert "Contract"     in types
      assert "Domain"       in types
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp sample_node(id, opts \\ []) do
    %{
      "id"         => id,
      "type"       => String.split(id, ":") |> hd(),
      "name"       => id,
      "content"    => "Sample content for #{id}",
      "implements" => Keyword.get(opts, :implements, []),
      "created_at" => "2024-01-01T00:00:00Z",
      "updated_at" => "2024-01-01T00:00:00Z"
    }
  end
end
