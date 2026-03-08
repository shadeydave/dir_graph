defmodule DirGraph.WeaverTest do
  use ExUnit.Case

  alias DirGraph.Weaver
  alias DirGraph.Graph, as: CG

  # Fixture source — line numbers must match the graph node metadata below.
  #
  # Line map:
  #   1: defmodule Sample do
  #   2:   def header, do: :header
  #   3:   def target_fn, do: :old_value   ← one-liner (replace action target)
  #   4:   def block_fn do                  ← start of multi-line block
  #   5:     :block_body
  #   6:   end                              ← end of block_fn
  #   7:   def footer, do: :footer          ← one-liner (insert_after / delete target)
  #   8: end
  #   9: (trailing empty line from heredoc)
  @source """
  defmodule Sample do
    def header, do: :header
    def target_fn, do: :old_value
    def block_fn do
      :block_body
    end
    def footer, do: :footer
  end
  """

  defp build_graph(file_path) do
    CG.new()
    |> CG.add_node("fn:target", "Function", "target_fn", %{file: file_path, line: 3, end_line: 3})
    |> CG.add_node("fn:block",  "Function", "block_fn",  %{file: file_path, line: 4, end_line: 6})
    |> CG.add_node("fn:footer", "Function", "footer",    %{file: file_path, line: 7, end_line: 7})
    |> CG.add_node("fn:target2","Function", "target2",   %{file: file_path, line: 3, end_line: 3})
  end

  defp write_fixture(tmp_dir, content \\ @source) do
    path = Path.join(tmp_dir, "sample.ex")
    File.write!(path, content)
    path
  end

  # ----------------------------------------------------------------
  # replace (single-line substitution)
  # ----------------------------------------------------------------

  describe "replace action" do
    @tag :tmp_dir
    test "replaces the target line and produces valid Elixir", %{tmp_dir: dir} do
      path = write_fixture(dir)
      g    = build_graph(path)

      {:ok, result} = Weaver.apply_diff(path, g, %{
        "mutations" => [%{
          "node_id"  => "fn:target",
          "action"   => "replace",
          "new_code" => "def target_fn, do: :replaced"
        }]
      })

      assert String.contains?(result, ":replaced")
      assert String.contains?(result, "def header")
      assert String.contains?(result, "def footer")
      refute String.contains?(result, ":old_value")
    end

    @tag :tmp_dir
    test "preserves the original line's indentation", %{tmp_dir: dir} do
      path = write_fixture(dir)
      g    = build_graph(path)

      {:ok, result} = Weaver.apply_diff(path, g, %{
        "mutations" => [%{
          "node_id"  => "fn:target",
          "action"   => "replace",
          "new_code" => "def target_fn, do: :new_body"
        }]
      })

      replaced_line = result |> String.split("\n") |> Enum.find(&String.contains?(&1, ":new_body"))
      assert String.starts_with?(replaced_line, "  ")
    end
  end

  # ----------------------------------------------------------------
  # replace_node (multi-line block substitution)
  # ----------------------------------------------------------------

  describe "replace_node action" do
    @tag :tmp_dir
    test "replaces entire block from line to end_line", %{tmp_dir: dir} do
      path = write_fixture(dir)
      g    = build_graph(path)

      {:ok, result} = Weaver.apply_diff(path, g, %{
        "mutations" => [%{
          "node_id"  => "fn:block",
          "action"   => "replace_node",
          "new_code" => "def block_fn, do: :rewritten"
        }]
      })

      assert String.contains?(result, "def block_fn, do: :rewritten")
      assert String.contains?(result, "def header")
      assert String.contains?(result, "def footer")
      refute String.contains?(result, ":block_body")
    end
  end

  # ----------------------------------------------------------------
  # insert_after
  # ----------------------------------------------------------------

  describe "insert_after action" do
    @tag :tmp_dir
    test "inserts a new line immediately after the target line", %{tmp_dir: dir} do
      path = write_fixture(dir)
      g    = build_graph(path)

      {:ok, result} = Weaver.apply_diff(path, g, %{
        "mutations" => [%{
          "node_id"  => "fn:footer",
          "action"   => "insert_after",
          "new_code" => "def injected, do: :new"
        }]
      })

      lines        = String.split(result, "\n")
      footer_idx   = Enum.find_index(lines, &String.contains?(&1, "def footer"))
      injected_idx = Enum.find_index(lines, &String.contains?(&1, "def injected"))

      assert injected_idx == footer_idx + 1
    end
  end

  # ----------------------------------------------------------------
  # delete
  # ----------------------------------------------------------------

  describe "delete action" do
    @tag :tmp_dir
    test "removes the target line", %{tmp_dir: dir} do
      path = write_fixture(dir)
      g    = build_graph(path)

      {:ok, result} = Weaver.apply_diff(path, g, %{
        "mutations" => [%{"node_id" => "fn:footer", "action" => "delete"}]
      })

      refute String.contains?(result, "def footer")
      assert String.contains?(result, "def header")
    end
  end

  # ----------------------------------------------------------------
  # Syntax verification
  # ----------------------------------------------------------------

  describe "syntax verification" do
    @tag :tmp_dir
    test "rejects a mutation producing invalid Elixir and does NOT write the file", %{tmp_dir: dir} do
      path     = write_fixture(dir)
      original = File.read!(path)
      g        = build_graph(path)

      result = Weaver.apply_diff(path, g, %{
        "mutations" => [%{
          "node_id"  => "fn:target",
          "action"   => "replace",
          "new_code" => "def broken({{{{ invalid syntax"
        }]
      })

      assert {:error, {:syntax_error, _reason, _src}} = result
      # File must be completely untouched
      assert File.read!(path) == original
    end

    @tag :tmp_dir
    test "accepts a valid mutation and writes the file", %{tmp_dir: dir} do
      path = write_fixture(dir)
      g    = build_graph(path)

      assert {:ok, _} = Weaver.apply_diff(path, g, %{
        "mutations" => [%{
          "node_id"  => "fn:target",
          "action"   => "replace",
          "new_code" => "def target_fn, do: :valid_replacement"
        }]
      })

      assert File.read!(path) |> String.contains?(":valid_replacement")
    end
  end

  # ----------------------------------------------------------------
  # Multiple mutations
  # ----------------------------------------------------------------

  describe "multiple mutations" do
    @tag :tmp_dir
    test "all mutations applied in correct reverse-line order", %{tmp_dir: dir} do
      path = write_fixture(dir)
      g    = build_graph(path)

      {:ok, result} = Weaver.apply_diff(path, g, %{
        "mutations" => [
          %{"node_id" => "fn:target", "action" => "replace", "new_code" => "def target_fn, do: :mutated_target"},
          %{"node_id" => "fn:footer", "action" => "replace", "new_code" => "def footer, do: :mutated_footer"}
        ]
      })

      assert String.contains?(result, ":mutated_target")
      assert String.contains?(result, ":mutated_footer")
    end
  end

  # ----------------------------------------------------------------
  # Error cases
  # ----------------------------------------------------------------

  describe "error cases" do
    test "raises RuntimeError (not File.Error) when node_id is not in graph" do
      g = CG.new()

      assert_raise RuntimeError, ~r/not found/i, fn ->
        Weaver.apply_diff("/tmp/fake_file_that_does_not_exist.ex", g, %{
          "mutations" => [%{"node_id" => "fn:ghost", "action" => "replace", "new_code" => "x"}]
        })
      end
    end
  end
end
