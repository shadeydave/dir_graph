ExUnit.start()

# Ensure the application (and all supervised GenServers) are started
# before tests run. Required for AttemptLedger, VectorStore, etc.
Application.ensure_all_started(:dir_graph)
