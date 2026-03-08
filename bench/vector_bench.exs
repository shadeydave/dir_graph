##
## DirGraph — VectorStore Cosine Similarity Benchmarks
##
## Shows search latency across different corpus sizes — the key question
## for GraphRAG: "can we find the right entry node fast enough?"
##
## Run with:
##   mix run bench/vector_bench.exs
##

Application.ensure_all_started(:dir_graph)

alias DirGraph.VectorStore

# ================================================================
# Setup: populate VectorStore with random unit vectors
# ================================================================

IO.puts("\n=== VectorStore Cosine Similarity Benchmarks ===\n")

# Embedding dimension — must match your backend model.
# nomic-embed-text: 768 dims   text-embedding-3-small: 1536 dims
dim = 768

# Helper: random unit vector in R^dim
random_unit_vector = fn dim ->
  raw  = for _ <- 1..dim, do: :rand.normal()
  norm = :math.sqrt(Enum.reduce(raw, 0.0, fn x, acc -> acc + x * x end))
  Enum.map(raw, fn x -> x / norm end)
end

query = random_unit_vector.(dim)

IO.puts("Vector dimension: #{dim}  (nomic-embed-text default)")
IO.puts("Building corpora...\n")

# Seed VectorStore with increasing corpus sizes.
# We'll benchmark across 100, 1_000, 10_000 vectors.

populate = fn n ->
  VectorStore.clear()
  for i <- 1..n do
    VectorStore.put("node:#{i}", random_unit_vector.(dim))
  end
end

# Pre-build corpora for each size (outside the timed section)
corpus_100   = for i <- 1..100,    do: {"node:#{i}", random_unit_vector.(dim)}
corpus_1000  = for i <- 1..1_000,  do: {"node:#{i}", random_unit_vector.(dim)}
corpus_10000 = for i <- 1..10_000, do: {"node:#{i}", random_unit_vector.(dim)}

IO.puts("Corpora built. Running benchmarks...\n")

# ================================================================
# Benchmark: search latency at different corpus sizes
# ================================================================

# Load 100-vector corpus for baseline
Enum.each(corpus_100, fn {id, v} -> VectorStore.put(id, v) end)
size_100_search = fn -> VectorStore.search(query, 10) end

# Load 1k-vector corpus
VectorStore.clear()
Enum.each(corpus_1000, fn {id, v} -> VectorStore.put(id, v) end)
size_1k_search = fn -> VectorStore.search(query, 10) end

# Load 10k-vector corpus
VectorStore.clear()
Enum.each(corpus_10000, fn {id, v} -> VectorStore.put(id, v) end)
size_10k_search = fn -> VectorStore.search(query, 10) end

Benchee.run(
  %{
    "cosine search top-10 / 100 vectors"    => size_100_search,
    "cosine search top-10 / 1,000 vectors"  => size_1k_search,
    "cosine search top-10 / 10,000 vectors" => size_10k_search,
  },
  time:        3,
  warmup:      1,
  memory_time: 1,
  formatters: [
    {Benchee.Formatters.Console, comparison: true, extended_statistics: true}
  ]
)

# ================================================================
# Manual timing: put + delete throughput
# ================================================================

IO.puts("\n=== VectorStore write throughput ===\n")

VectorStore.clear()
v = random_unit_vector.(dim)

{put_us, _} = :timer.tc(fn ->
  for i <- 1..1000, do: VectorStore.put("bench:#{i}", v)
end)

IO.puts("1,000 puts:       #{put_us} μs  (#{round(put_us / 1000)} μs/put)")
IO.puts("Stored vectors:   #{VectorStore.size()}")

{del_us, _} = :timer.tc(fn ->
  for i <- 1..1000, do: VectorStore.delete("bench:#{i}")
end)

IO.puts("1,000 deletes:    #{del_us} μs  (#{round(del_us / 1000)} μs/delete)")

# ================================================================
# Correctness spot-check
# ================================================================

IO.puts("\n=== Correctness spot-check ===\n")

VectorStore.clear()

# A known query and a known close vector
target   = [1.0, 0.0, 0.0] ++ List.duplicate(0.0, dim - 3) ++ [0.0]
close    = [0.99, 0.14, 0.0] ++ List.duplicate(0.0, dim - 3) ++ [0.0]
far      = [0.0, 0.0, 1.0] ++ List.duplicate(0.0, dim - 3) ++ [0.0]
opposite = [-1.0, 0.0, 0.0] ++ List.duplicate(0.0, dim - 3) ++ [0.0]

# Normalise
normalise = fn v ->
  n = :math.sqrt(Enum.reduce(v, 0.0, fn x, acc -> acc + x * x end))
  Enum.map(v, &(&1 / n))
end

VectorStore.put("target",   normalise.(target))
VectorStore.put("close",    normalise.(close))
VectorStore.put("far",      normalise.(far))
VectorStore.put("opposite", normalise.(opposite))

results = VectorStore.search(normalise.(target), 4)

IO.puts("Query direction: [1, 0, 0, ...]")
IO.puts("Expected ranking: target > close > far > opposite\n")
Enum.each(results, fn {id, score} ->
  IO.puts("  #{String.pad_trailing(id, 10)} score=#{Float.round(score, 4)}")
end)

[{top_id, _} | _] = results
if top_id == "target" do
  IO.puts("\nCORRECT: most similar node is 'target'")
else
  IO.puts("\nFAIL: expected 'target', got '#{top_id}'")
end

IO.puts("\nDone.\n")
