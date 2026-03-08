defmodule DirGraph.MixProject do
  use Mix.Project

  def project do
    [
      app: :dir_graph,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: DirGraph.CLI],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {DirGraph.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:libgraph, "~> 0.16.0"},
      {:the_fuzz, "~> 0.6.0"},
      {:file_system, "~> 1.0"},
      {:req, "~> 0.5"},
      {:benchee, "~> 1.3", only: :dev}
    ]
  end
end
