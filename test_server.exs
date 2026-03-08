# test_server.exs
# The application automatically starts the DirGraph.Supervisor which starts DirGraph.Server

IO.puts("Indexing file through GenServer...")
DirGraph.Server.index_file("test_spec.ex")

# Let the cast run
:timer.sleep(100)

IO.puts("Extracting slice for 'login' from GenServer state...")
case DirGraph.Server.extract_slice("login") do
  {:ok, slice} -> 
    IO.inspect(slice)
  {:error, _} ->
    IO.puts("Failed to extract slice.")
end
