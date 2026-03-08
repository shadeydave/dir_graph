defmodule DirGraph.Manifest do
  @moduledoc """
  Tracks file metadata (mtime + size) so graph-to-disk sync is delta-only.

  ## Two sync scenarios

  ### Startup sync
  A `.bin` graph was built in a previous session. Files may have been added,
  edited, or deleted since. `diff/2` compares the saved manifest against the
  current state of the directory and returns exactly which files changed —
  so only those get re-indexed rather than the whole project.

  ### Live sync (Watcher)
  `DirGraph.Watcher` fires on individual file events. The manifest is updated
  after each re-index so it always reflects what the graph actually contains.

  ## Why mtime + size instead of content hash?
  Hashing every file on every sync is expensive on large projects. mtime alone
  can be wrong (e.g. `touch` without editing), so we use both: mtime as the
  fast path, size as a cheap second check. This matches what make and mix use.
  """

  @type entry :: %{mtime: :calendar.datetime(), size: non_neg_integer()}
  @type t :: %{String.t() => entry()}

  @doc "Build a manifest for a list of absolute file paths from current disk state."
  @spec build([String.t()]) :: t()
  def build(file_paths) when is_list(file_paths) do
    Enum.reduce(file_paths, %{}, fn path, acc ->
      case read_stat(path) do
        {:ok, entry} -> Map.put(acc, path, entry)
        :error -> acc
      end
    end)
  end

  @doc """
  Compares a saved manifest against the current state of `current_paths`.

  Returns `%{new: [...], modified: [...], deleted: [...]}` — the minimal set
  of operations needed to bring the graph in sync with disk.
  """
  @spec diff(t(), [String.t()]) :: %{new: [String.t()], modified: [String.t()], deleted: [String.t()]}
  def diff(old_manifest, current_paths) when is_map(old_manifest) do
    current = build(current_paths)

    old_set     = MapSet.new(Map.keys(old_manifest))
    current_set = MapSet.new(Map.keys(current))

    deleted  = old_set |> MapSet.difference(current_set) |> MapSet.to_list()
    new      = current_set |> MapSet.difference(old_set) |> MapSet.to_list()

    modified =
      current
      |> Enum.filter(fn {path, entry} ->
        case Map.get(old_manifest, path) do
          nil  -> false
          old  -> old.mtime != entry.mtime or old.size != entry.size
        end
      end)
      |> Enum.map(fn {path, _} -> path end)

    %{new: new, modified: modified, deleted: deleted}
  end

  def diff(%{}, _), do: %{new: [], modified: [], deleted: []}

  @doc """
  Derives a manifest from an already-built graph by reading current disk stats
  for every File node. Used by `Indexer.save_graph/2` to embed a manifest
  snapshot alongside the graph binary.
  """
  @spec from_graph(Graph.t()) :: t()
  def from_graph(graph) do
    graph
    |> Graph.vertices()
    |> Enum.flat_map(fn vid ->
      case DirGraph.Graph.get_label(graph, vid) do
        %{type: "File", path: path} ->
          case read_stat(path) do
            {:ok, entry} -> [{path, entry}]
            :error -> []
          end
        _ -> []
      end
    end)
    |> Enum.into(%{})
  end

  # ----------------------------------------------------------------

  defp read_stat(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime, size: size}} -> {:ok, %{mtime: mtime, size: size}}
      _ -> :error
    end
  end
end
