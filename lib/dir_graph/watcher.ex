defmodule DirGraph.Watcher do
  @moduledoc """
  Watches one or more directories for file-system changes and keeps
  `DirGraph.Server`'s in-memory graph in sync automatically.

  Uses the `file_system` library which wraps FSEvents (macOS), inotify
  (Linux), and kqueue (BSD) behind a unified interface.

  ## Debouncing

  Most editors write a file in multiple rapid steps (temp file → rename,
  or multiple partial writes). A 150ms debounce window per file prevents
  a single logical save from triggering multiple re-indexes.

  ## What triggers what

      :created   → Server.index_file/1
      :modified  → Server.index_file/1  (purge+re-index handled by Server)
      :removed   → Server.remove_file/1
      :renamed   → Server.index_file/1  (old path is purged via stale-node cleanup)

  Only files matching `@watched_extensions` and not under ignored directories
  are processed. Everything else is silently dropped.
  """

  use GenServer

  alias DirGraph.Server

  @debounce_ms 150

  @watched_extensions ~w(.ex .exs .js .jsx .ts .tsx .py .rb .go .rs)

  @ignored_dirs ~w(/node_modules/ /_build/ /deps/ /.git/)

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Start watching `dir_path`. Idempotent — watching the same dir twice is a no-op."
  def watch(dir_path), do: GenServer.call(__MODULE__, {:watch, Path.expand(dir_path)})

  @doc "Stop watching `dir_path`."
  def unwatch(dir_path), do: GenServer.call(__MODULE__, {:unwatch, Path.expand(dir_path)})

  @doc "Returns all currently watched directories."
  def watched_dirs, do: GenServer.call(__MODULE__, :watched_dirs)

  # ----------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    # watchers: %{dir_path => fs_pid}
    # pending:  %{file_path => timer_ref}  (debounce timers)
    {:ok, %{watchers: %{}, pending: %{}}}
  end

  @impl true
  def handle_call({:watch, dir}, _from, state) do
    if Map.has_key?(state.watchers, dir) do
      {:reply, :already_watching, state}
    else
      case FileSystem.start_link(dirs: [dir]) do
        {:ok, fs_pid} ->
          FileSystem.subscribe(fs_pid)
          {:reply, :ok, put_in(state, [:watchers, dir], fs_pid)}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:unwatch, dir}, _from, state) do
    case Map.pop(state.watchers, dir) do
      {nil, _} ->
        {:reply, :not_watching, state}

      {fs_pid, watchers} ->
        Process.exit(fs_pid, :normal)
        {:reply, :ok, %{state | watchers: watchers}}
    end
  end

  @impl true
  def handle_call(:watched_dirs, _from, state) do
    {:reply, Map.keys(state.watchers), state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    if relevant?(path) do
      state = debounce(state, path, events)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:apply_event, path, events}, state) do
    state = %{state | pending: Map.delete(state.pending, path)}
    dispatch(path, events)
    {:noreply, state}
  end

  # Swallow FileSystem lifecycle messages
  def handle_info(_, state), do: {:noreply, state}

  # ----------------------------------------------------------------
  # Debounce
  # ----------------------------------------------------------------

  defp debounce(state, path, events) do
    # Cancel any existing timer for this path
    state =
      case Map.get(state.pending, path) do
        nil -> state
        ref ->
          Process.cancel_timer(ref)
          %{state | pending: Map.delete(state.pending, path)}
      end

    ref = Process.send_after(self(), {:apply_event, path, events}, @debounce_ms)
    put_in(state, [:pending, path], ref)
  end

  # ----------------------------------------------------------------
  # Event dispatch → Server operations
  # ----------------------------------------------------------------

  defp dispatch(path, events) do
    cond do
      :removed in events ->
        Server.remove_file(path)

      :created in events or :modified in events or :renamed in events ->
        Server.index_file(path)

      true ->
        :ok
    end
  end

  # ----------------------------------------------------------------
  # Filtering
  # ----------------------------------------------------------------

  defp relevant?(path) do
    Path.extname(path) in @watched_extensions and
      not Enum.any?(@ignored_dirs, &String.contains?(path, &1))
  end
end
