defmodule DirGraph.AttemptLedger do
  @moduledoc """
  Tracks fix attempts per named problem to prevent the agent from oscillating
  in a local minimum.

  ## The problem

  An autonomous fix loop can get stuck:
  - Attempting the same failing approach repeatedly (local minimum)
  - Fixing problem A in a way that breaks B, then fixing B in a way that
    breaks A — flip-flopping indefinitely

  ## How this solves it

  The agent calls `record_attempt/1` before each fix attempt. It gets back
  the attempt count plus a contextual message. The agent doesn't track state —
  the ledger does. At attempt 3, the agent is told to try a different approach.
  On recurrence (problem was resolved, then came back), it's flagged as a
  potential flip-flop.

  ## Lifecycle

      record_attempt("verify_token")   → attempt 1, no warning
      record_attempt("verify_token")   → attempt 2, note
      record_attempt("verify_token")   → attempt 3, warning: try something different

      resolve_problem("verify_token")  → marked fixed

      record_attempt("verify_token")   → recurrence 1, immediate warning: this came back

  ## Problem keys

  Keys are free-form strings. Use whatever identifies the problem naturally:
  a test name, a function name, an error message prefix, a ticket ID.
  The ledger does not interpret them — it only counts.
  """

  use GenServer

  @warn_at_attempt 3
  @error_at_attempt 5

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Record a fix attempt for `key`. Returns a map the agent should read before
  proceeding — it contains the attempt count and any guidance message.

  Pass `diagnostic` (the error message or test failure output) to enable
  fingerprint tracking. If the same diagnostic fingerprint repeats across
  consecutive attempts — meaning different code changes produced the same
  error — the response includes a specific warning that the root cause mental
  model is likely wrong, before the standard count-based thresholds fire.

      %{
        key:         "verify_token",
        attempt:     2,
        recurrences: 0,
        status:      "open",
        first_seen:  "2024-...",
        message:     "Same error as previous attempt. Different code, same failure ..."
      }
  """
  def record_attempt(key, diagnostic \\ nil) do
    GenServer.call(__MODULE__, {:record_attempt, key, diagnostic})
  end

  @doc """
  Mark `key` as resolved. Clears the attempt counter but retains history.
  If this problem recurs later, `record_attempt` will flag it as a regression.
  """
  def resolve_problem(key) do
    GenServer.call(__MODULE__, {:resolve, key})
  end

  @doc "Returns the full ledger entry for `key`, or nil if unseen."
  def get_history(key) do
    GenServer.call(__MODULE__, {:history, key})
  end

  @doc "Returns all open problems (unresolved, sorted by attempt count descending)."
  def list_problems do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Wipe the entire ledger. Useful at session start."
  def reset_all do
    GenServer.call(__MODULE__, :reset_all)
  end

  # ----------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:record_attempt, key, diagnostic}, _from, ledger) do
    now = DateTime.utc_now()
    entry = Map.get(ledger, key)
    fingerprint = if diagnostic, do: :erlang.phash2(diagnostic), else: nil

    {new_entry, response} =
      case entry do
        nil ->
          e = new_entry(key, now, diagnostic, fingerprint)
          {e, build_response(e)}

        %{status: :resolved} = e ->
          e = %{
            e
            | status: :open,
              attempt: 1,
              recurrences: e.recurrences + 1,
              last_seen: now,
              last_diagnostic: diagnostic,
              last_fingerprint: fingerprint
          }

          {e, build_response(e)}

        e ->
          same_error = fingerprint != nil and fingerprint == e.last_fingerprint

          e = %{
            e
            | attempt: e.attempt + 1,
              last_seen: now,
              last_diagnostic: diagnostic,
              last_fingerprint: fingerprint,
              same_error: same_error
          }

          {e, build_response(e)}
      end

    {:reply, response, Map.put(ledger, key, new_entry)}
  end

  @impl true
  def handle_call({:resolve, key}, _from, ledger) do
    ledger =
      case Map.get(ledger, key) do
        nil ->
          ledger

        entry ->
          Map.put(ledger, key, %{entry | status: :resolved, resolved_at: DateTime.utc_now()})
      end

    {:reply, :ok, ledger}
  end

  @impl true
  def handle_call({:history, key}, _from, ledger) do
    {:reply, Map.get(ledger, key), ledger}
  end

  @impl true
  def handle_call(:list, _from, ledger) do
    problems =
      ledger
      |> Enum.filter(fn {_, e} -> e.status == :open end)
      |> Enum.sort_by(fn {_, e} -> e.attempt end, :desc)
      |> Enum.map(fn {_, e} -> summarise(e) end)

    {:reply, problems, ledger}
  end

  @impl true
  def handle_call(:reset_all, _from, _ledger) do
    {:reply, :ok, %{}}
  end

  # ----------------------------------------------------------------
  # Private
  # ----------------------------------------------------------------

  defp new_entry(key, now, diagnostic, fingerprint) do
    %{
      key: key,
      attempt: 1,
      recurrences: 0,
      status: :open,
      first_seen: now,
      last_seen: now,
      resolved_at: nil,
      last_diagnostic: diagnostic,
      last_fingerprint: fingerprint,
      same_error: false
    }
  end

  defp build_response(%{same_error: true} = entry) do
    Map.merge(summarise(entry), %{
      message: """
      Attempt #{entry.attempt} on '#{entry.key}': the diagnostic fingerprint is \
      identical to the previous attempt — different code, same failure. \
      Your mental model of the root cause is likely incorrect. \
      Before trying again, re-read the affected_by slice for the relevant \
      function and reconsider what is actually causing this error.
      """
    })
  end

  defp build_response(%{recurrences: r} = entry) when r > 0 do
    Map.merge(summarise(entry), %{
      message: """
      Regression: '#{entry.key}' was previously resolved but has recurred \
      #{entry.recurrences} time(s). This is a strong signal of a flip-flop — \
      fixing this is breaking something else, or the fix is not persisting. \
      Step back and look at the interaction between recent changes before attempting again.
      """
    })
  end

  defp build_response(%{attempt: n} = entry) when n >= @error_at_attempt do
    Map.merge(summarise(entry), %{
      message: """
      #{n} attempts on '#{entry.key}' with no resolution. \
      Continuing on the same path is unlikely to work. \
      Stop, explain what has been tried, and ask for guidance or take a \
      fundamentally different approach.
      """
    })
  end

  defp build_response(%{attempt: n} = entry) when n >= @warn_at_attempt do
    Map.merge(summarise(entry), %{
      message: """
      #{n} attempts on '#{entry.key}'. The current approach may be stuck. \
      Before trying again, reconsider the root cause — is the problem \
      actually what it appears to be?
      """
    })
  end

  defp build_response(%{attempt: 2} = entry) do
    Map.merge(summarise(entry), %{
      message:
        "Second attempt on '#{entry.key}'. If the last fix didn't hold, check whether the approach itself is sound."
    })
  end

  defp build_response(entry) do
    Map.merge(summarise(entry), %{message: nil})
  end

  defp summarise(entry) do
    %{
      key: entry.key,
      attempt: entry.attempt,
      recurrences: entry.recurrences,
      status: Atom.to_string(entry.status),
      first_seen: DateTime.to_iso8601(entry.first_seen),
      last_seen: DateTime.to_iso8601(entry.last_seen)
    }
  end
end
