defmodule DirGraphTest do
  # Smoke test — verifies the application boots and the supervision tree
  # starts without error. Real tests live in test/dir_graph/*.
  use ExUnit.Case, async: true

  test "application starts all supervised processes" do
    assert Process.whereis(DirGraph.Server)        != nil
    assert Process.whereis(DirGraph.Watcher)       != nil
    assert Process.whereis(DirGraph.ProcessMonitor) != nil
    assert Process.whereis(DirGraph.AttemptLedger) != nil
    assert Process.whereis(DirGraph.VectorStore)   != nil
    assert Process.whereis(DirGraph.RAG)           != nil
  end
end
