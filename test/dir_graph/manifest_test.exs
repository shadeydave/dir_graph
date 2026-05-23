defmodule DirGraph.ManifestTest do
  use ExUnit.Case, async: true

  alias DirGraph.Manifest

  # ----------------------------------------------------------------
  # build/1
  # ----------------------------------------------------------------

  describe "build/1" do
    @tag :tmp_dir
    test "captures mtime and size for each file", %{tmp_dir: dir} do
      path = Path.join(dir, "a.ex")
      content = "defmodule A do end"
      File.write!(path, content)

      manifest = Manifest.build([path])

      assert Map.has_key?(manifest, path)
      assert manifest[path].size == byte_size(content)
      assert manifest[path].mtime != nil
    end

    @tag :tmp_dir
    test "handles multiple files", %{tmp_dir: dir} do
      paths =
        for i <- 1..3 do
          p = Path.join(dir, "file_#{i}.ex")
          File.write!(p, "content #{i}")
          p
        end

      manifest = Manifest.build(paths)
      assert map_size(manifest) == 3
    end

    test "returns empty map for empty file list" do
      assert Manifest.build([]) == %{}
    end
  end

  # ----------------------------------------------------------------
  # diff/2
  # ----------------------------------------------------------------

  describe "diff/2" do
    @tag :tmp_dir
    test "detects files present in current but absent from manifest as :new", %{tmp_dir: dir} do
      path = Path.join(dir, "new_file.ex")
      File.write!(path, "new content")
      diff = Manifest.diff(%{}, [path])
      assert path in diff.new
    end

    @tag :tmp_dir
    test "detects files in manifest but absent from current as :deleted", %{tmp_dir: dir} do
      path = Path.join(dir, "will_vanish.ex")
      File.write!(path, "content")
      old = Manifest.build([path])
      # File is "gone" — not present in the current file list
      diff = Manifest.diff(old, [])
      assert path in diff.deleted
    end

    @tag :tmp_dir
    test "detects changed files as :modified (size change)", %{tmp_dir: dir} do
      path = Path.join(dir, "changing.ex")
      File.write!(path, "short")
      old = Manifest.build([path])

      # Write more content — size changes
      File.write!(path, "this is now much longer content")
      diff = Manifest.diff(old, [path])

      assert path in diff.modified
    end

    @tag :tmp_dir
    test "unchanged files appear in none of the buckets", %{tmp_dir: dir} do
      path = Path.join(dir, "stable.ex")
      File.write!(path, "stable content here")
      old = Manifest.build([path])
      diff = Manifest.diff(old, [path])

      refute path in diff.new
      refute path in diff.modified
      refute path in diff.deleted
    end

    @tag :tmp_dir
    test "mixed scenario: new + modified + deleted + unchanged", %{tmp_dir: dir} do
      stable = Path.join(dir, "stable.ex")
      changed = Path.join(dir, "changed.ex")
      deleted = Path.join(dir, "deleted.ex")
      new_f = Path.join(dir, "new.ex")

      File.write!(stable, "stable")
      File.write!(changed, "original")
      File.write!(deleted, "going away")

      old = Manifest.build([stable, changed, deleted])

      File.write!(changed, "different content now longer")
      File.write!(new_f, "brand new file")

      diff = Manifest.diff(old, [stable, changed, new_f])

      assert new_f in diff.new
      assert changed in diff.modified
      assert deleted in diff.deleted
      refute stable in diff.new
      refute stable in diff.modified
      refute stable in diff.deleted
    end
  end
end
