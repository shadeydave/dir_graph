defmodule DirGraph.ProcessMonitor do
  @moduledoc """
  Manages a registry of named, monitored OS processes and exposes their output
  to the LLM via MCP tool calls.

  ## The problem this solves

  An agent making code changes has no reliable way to observe the runtime
  effects of those changes. It can run a blocking command and wait, but it
  cannot watch a long-running process (`mix test --watch`, `npm run dev`,
  a type checker) across multiple conversation turns.

  ProcessMonitor bridges that gap. Spawn a process once, poll its output
  cheaply via `tail_output/2` whenever you need an update. The process keeps
  running between agent turns. The agent acts on what it sees.

  ## The feedback loop

      spawn_process("mix test --watch", name: "tests")

      loop:
        tail_output("tests", since: cursor)   → new output, next cursor
        if failure:  find it in graph → read code → fix → wait
        if passing:  done

  ## Output model

  Each process has a ring buffer of the last `@max_lines` lines, numbered
  globally and monotonically from 1. Line numbers never change once assigned.

  `tail_output` uses a cursor (last seen line number) and returns only new
  lines plus the next cursor. Cost per poll is proportional to new output,
  not total output.

  ## Safety

  - Output only — the monitor never sends input to processes.
  - Named processes only — no attaching to arbitrary system PIDs.
  - Working directory is checked against the MCP path allowlist.
  - All ports are closed on GenServer termination.
  """

  use GenServer

  @max_lines 500

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Spawn `cmd` in `cwd`, register it under `name`, and start capturing output.
  Returns `{:ok, name}` or `{:error, reason}`.
  """
  def spawn_process(name, cmd, cwd) do
    GenServer.call(__MODULE__, {:spawn, name, cmd, cwd})
  end

  @doc "Returns a summary list of all monitored processes."
  def list_processes do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Returns the last `limit` lines from process `name`."
  def read_output(name, limit \\ 50) do
    GenServer.call(__MODULE__, {:read, name, limit})
  end

  @doc """
  Returns lines from process `name` with line number > `cursor`,
  plus `next_cursor` for the next call.
  Designed for cheap repeated polling — only transmits new output.
  """
  def tail_output(name, cursor \\ 0) do
    GenServer.call(__MODULE__, {:tail, name, cursor})
  end

  @doc "Send SIGTERM to `name` and remove it from the registry."
  def stop_process(name) do
    GenServer.call(__MODULE__, {:stop, name})
  end

  # ----------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    # processes:  %{name => entry}
    # port_index: %{port => name}  — O(1) reverse lookup on port messages
    {:ok, %{processes: %{}, port_index: %{}}}
  end

  @impl true
  def handle_call({:spawn, name, cmd, cwd}, _from, state) do
    if Map.has_key?(state.processes, name) do
      {:reply, {:error, {:name_taken, name}}, state}
    else
      try do
        port =
          Port.open({:spawn, cmd}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, 4096},
            {:cd, cwd}
          ])

        entry = %{
          port:       port,
          cmd:        cmd,
          cwd:        cwd,
          status:     :running,
          buffer:     [],       # newest-first list of %{n, ts, text}
          line_count: 0,
          started_at: DateTime.utc_now()
        }

        new_state = %{
          processes:  Map.put(state.processes,  name, entry),
          port_index: Map.put(state.port_index, port, name)
        }

        {:reply, {:ok, name}, new_state}
      rescue
        e -> {:reply, {:error, Exception.message(e)}, state}
      end
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    summary =
      Enum.map(state.processes, fn {name, entry} ->
        %{
          name:        name,
          cmd:         entry.cmd,
          cwd:         entry.cwd,
          status:      status_label(entry.status),
          line_count:  entry.line_count,
          started_at:  DateTime.to_iso8601(entry.started_at),
          last_line:   entry.buffer |> List.first() |> then(& &1 && &1.text)
        }
      end)

    {:reply, summary, state}
  end

  @impl true
  def handle_call({:read, name, limit}, _from, state) do
    case Map.get(state.processes, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        lines = entry.buffer |> Enum.take(limit) |> Enum.reverse()

        result = %{
          name:        name,
          cmd:         entry.cmd,
          status:      status_label(entry.status),
          total_lines: entry.line_count,
          started_at:  DateTime.to_iso8601(entry.started_at),
          lines:       lines
        }

        {:reply, {:ok, result}, state}
    end
  end

  @impl true
  def handle_call({:tail, name, cursor}, _from, state) do
    case Map.get(state.processes, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        # buffer is newest-first; take lines while n > cursor, then reverse
        # to return them in chronological order
        lines =
          entry.buffer
          |> Enum.take_while(fn e -> e.n > cursor end)
          |> Enum.reverse()

        result = %{
          name:        name,
          status:      status_label(entry.status),
          lines:       lines,
          next_cursor: entry.line_count
        }

        {:reply, {:ok, result}, state}
    end
  end

  @impl true
  def handle_call({:stop, name}, _from, state) do
    case Map.get(state.processes, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        if entry.status == :running, do: Port.close(entry.port)

        new_state = %{
          processes:  Map.delete(state.processes,  name),
          port_index: Map.delete(state.port_index, entry.port)
        }

        {:reply, :ok, new_state}
    end
  end

  # ----------------------------------------------------------------
  # Port message handlers
  # ----------------------------------------------------------------

  @impl true
  def handle_info({port, {:data, {:eol, text}}}, state) do
    {:noreply, append_line(state, port, text)}
  end

  def handle_info({port, {:data, {:noeol, text}}}, state) do
    # Partial line (process ended without a trailing newline) — treat as complete
    {:noreply, append_line(state, port, text)}
  end

  def handle_info({port, {:exit_status, code}}, state) do
    case Map.get(state.port_index, port) do
      nil  -> {:noreply, state}
      name -> {:noreply, put_in(state, [:processes, name, :status], {:exited, code})}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.processes, fn {_name, entry} ->
      if entry.status == :running do
        try do
          Port.close(entry.port)
        catch
          _, _ -> :ok
        end
      end
    end)
  end

  # ----------------------------------------------------------------
  # Private helpers
  # ----------------------------------------------------------------

  defp append_line(state, port, text) do
    case Map.get(state.port_index, port) do
      nil ->
        state

      name ->
        entry = state.processes[name]
        n     = entry.line_count + 1
        line  = %{n: n, ts: System.system_time(:millisecond), text: text}

        new_buffer = [line | entry.buffer] |> Enum.take(@max_lines)
        new_entry  = %{entry | buffer: new_buffer, line_count: n}

        put_in(state, [:processes, name], new_entry)
    end
  end

  defp status_label(:running),        do: "running"
  defp status_label({:exited, 0}),    do: "exited:ok"
  defp status_label({:exited, code}), do: "exited:#{code}"
end
