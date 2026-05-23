import Config

config :dir_graph,
  neo4j_url: System.get_env("DIRGRAPH_NEO4J_URL", "http://localhost:7475"),
  neo4j_user: System.get_env("DIRGRAPH_NEO4J_USER", "neo4j"),
  neo4j_pass: System.get_env("DIRGRAPH_NEO4J_PASS", "dirgraph")

config :logger, :console, device: :standard_error

config :logger, :default_handler,
  config: [
    type: :standard_error
  ]
