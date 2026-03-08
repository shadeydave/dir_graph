defmodule DirGraph.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DirGraph.Server,
      DirGraph.Watcher,
      DirGraph.ProcessMonitor,
      DirGraph.AttemptLedger,
      DirGraph.VectorStore,
      DirGraph.RAG
    ]

    opts = [strategy: :one_for_one, name: DirGraph.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
