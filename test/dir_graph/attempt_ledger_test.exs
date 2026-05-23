defmodule DirGraph.AttemptLedgerTest do
  # NOT async — tests share the running AttemptLedger GenServer.
  use ExUnit.Case

  alias DirGraph.AttemptLedger

  setup do
    AttemptLedger.reset_all()
    :ok
  end

  # ----------------------------------------------------------------
  # record_attempt/1 — first attempt
  # ----------------------------------------------------------------

  describe "first attempt" do
    test "returns attempt count of 1" do
      result = AttemptLedger.record_attempt("verify_token")
      assert result.attempt == 1
    end

    test "status is open" do
      result = AttemptLedger.record_attempt("verify_token")
      assert result.status == "open"
    end

    test "recurrences is 0" do
      result = AttemptLedger.record_attempt("verify_token")
      assert result.recurrences == 0
    end

    test "message is nil on first attempt" do
      result = AttemptLedger.record_attempt("verify_token")
      assert result.message == nil
    end

    test "includes first_seen and last_seen timestamps" do
      result = AttemptLedger.record_attempt("verify_token")
      assert is_binary(result.first_seen)
      assert is_binary(result.last_seen)
    end
  end

  # ----------------------------------------------------------------
  # record_attempt/1 — graduated warnings
  # ----------------------------------------------------------------

  describe "graduated warnings" do
    test "attempt 2 returns a non-nil message" do
      AttemptLedger.record_attempt("slow_bug")
      result = AttemptLedger.record_attempt("slow_bug")

      assert result.attempt == 2
      assert is_binary(result.message)
      assert result.message != nil
    end

    test "attempt 3 returns a warning message" do
      for _ <- 1..2, do: AttemptLedger.record_attempt("stuck_bug")
      result = AttemptLedger.record_attempt("stuck_bug")

      assert result.attempt == 3
      assert String.length(result.message) > 0
    end

    test "attempt 5 returns a stop-and-reconsider message" do
      for _ <- 1..4, do: AttemptLedger.record_attempt("broken_thing")
      result = AttemptLedger.record_attempt("broken_thing")

      assert result.attempt == 5
      # The error-level message should be more urgent than the warning
      assert String.length(result.message) > 0
    end

    test "attempt count increments correctly across multiple calls" do
      results = for _ <- 1..5, do: AttemptLedger.record_attempt("count_check")
      counts = Enum.map(results, & &1.attempt)
      assert counts == [1, 2, 3, 4, 5]
    end
  end

  # ----------------------------------------------------------------
  # resolve_problem/1
  # ----------------------------------------------------------------

  describe "resolve_problem/1" do
    test "marks the problem as resolved" do
      AttemptLedger.record_attempt("to_resolve")
      AttemptLedger.resolve_problem("to_resolve")

      # After resolution, list_problems should not include it
      open_keys = AttemptLedger.list_problems() |> Enum.map(& &1.key)
      refute "to_resolve" in open_keys
    end

    test "is a no-op for an unknown key" do
      assert :ok = AttemptLedger.resolve_problem("unknown_key")
    end
  end

  # ----------------------------------------------------------------
  # Recurrence detection
  # ----------------------------------------------------------------

  describe "recurrence detection" do
    test "recurrence count increments after resolve + re-attempt" do
      AttemptLedger.record_attempt("flip_flop")
      AttemptLedger.resolve_problem("flip_flop")
      result = AttemptLedger.record_attempt("flip_flop")

      assert result.recurrences == 1
      assert result.attempt == 1
    end

    test "recurrence resets attempt count to 1" do
      for _ <- 1..3, do: AttemptLedger.record_attempt("recurring")
      AttemptLedger.resolve_problem("recurring")
      result = AttemptLedger.record_attempt("recurring")

      assert result.attempt == 1
    end

    test "recurrence message is immediately flagged (not waiting for threshold)" do
      AttemptLedger.record_attempt("flip_flop")
      AttemptLedger.resolve_problem("flip_flop")
      result = AttemptLedger.record_attempt("flip_flop")

      assert is_binary(result.message)

      assert String.contains?(String.downcase(result.message), "recur") or
               String.contains?(String.downcase(result.message), "regression") or
               String.contains?(String.downcase(result.message), "flip")
    end

    test "multiple recurrences are tracked" do
      for _ <- 1..3 do
        AttemptLedger.record_attempt("recurring")
        AttemptLedger.resolve_problem("recurring")
      end

      result = AttemptLedger.record_attempt("recurring")
      assert result.recurrences == 3
    end
  end

  # ----------------------------------------------------------------
  # list_problems/0
  # ----------------------------------------------------------------

  describe "list_problems/0" do
    test "returns only open problems" do
      AttemptLedger.record_attempt("open_one")
      AttemptLedger.record_attempt("open_two")
      AttemptLedger.record_attempt("to_close")
      AttemptLedger.resolve_problem("to_close")

      keys = AttemptLedger.list_problems() |> Enum.map(& &1.key)
      assert "open_one" in keys
      assert "open_two" in keys
      refute "to_close" in keys
    end

    test "returns empty list when no open problems" do
      assert AttemptLedger.list_problems() == []
    end

    test "sorts by attempt count descending" do
      AttemptLedger.record_attempt("low")
      for _ <- 1..3, do: AttemptLedger.record_attempt("high")

      [first | _] = AttemptLedger.list_problems()
      assert first.key == "high"
    end
  end

  # ----------------------------------------------------------------
  # reset_all/0
  # ----------------------------------------------------------------

  describe "reset_all/0" do
    test "clears the entire ledger" do
      for key <- ~w(a b c), do: AttemptLedger.record_attempt(key)
      AttemptLedger.reset_all()
      assert AttemptLedger.list_problems() == []
    end
  end

  # ----------------------------------------------------------------
  # Independent keys
  # ----------------------------------------------------------------

  describe "independent problem keys" do
    test "different keys do not interfere with each other" do
      AttemptLedger.record_attempt("key_a")
      AttemptLedger.record_attempt("key_a")
      AttemptLedger.record_attempt("key_b")

      result_a = AttemptLedger.record_attempt("key_a")
      result_b = AttemptLedger.record_attempt("key_b")

      assert result_a.attempt == 3
      assert result_b.attempt == 2
    end
  end
end
