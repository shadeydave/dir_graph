defmodule DirGraph.Dream do
  @moduledoc """
  Background enrichment engine — the "DREAM pass".

  While the system is idle, Dream pulls un-enriched Function and Module nodes
  from a queue and sends their source code to a local LLM (via Ollama) to generate
  structured metadata: a plain-English summary, domain classification, semantic tags,
  and a complexity estimate.

  Enriched nodes are stored in DirGraph.EnrichmentStore (ETS) and written to Neo4j
  for persistence. The RAG layer automatically uses enrichment when building embedding
  text, so semantic search quality improves progressively as Dream works through the
  graph.

  ## Concurrency

  Dream fires up to `concurrency` parallel Ollama requests using Task.async_stream.
  Set OLLAMA_NUM_PARALLEL to the same value before starting Ollama so the server
  actually processes them concurrently (continuous batching via llama.cpp).

      launchctl setenv OLLAMA_NUM_PARALLEL 4
      # Quit and restart Ollama from the menu bar

  ## Model choice

  Default: "qwen3:8b" — fast (~80 tok/s on M3 Ultra), good code comprehension.
  Override via mcp_config.json:

      { "dream": { "model": "qwen3-coder:30b", "concurrency": 2 } }

  ## Node priority

  Only Function and Module nodes are enriched — Calls, Variables, and Files
  add noise without meaningful summary potential. Nodes already in EnrichmentStore
  are skipped automatically.
  """

  use GenServer
  require Logger

  alias DirGraph.{EnrichmentStore, Neo4j}
  alias DirGraph.Graph, as: CG

  @config_path ".dir_graph/mcp_config.json"
  @tick_ms 3_000
  @enrichable_types ~w(Function Module)
  @ollama_timeout 60_000

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Queue all enrichable nodes in `graph` for background enrichment."
  @spec enqueue_graph(Graph.t()) :: :ok
  def enqueue_graph(graph) do
    GenServer.cast(__MODULE__, {:enqueue_graph, graph})
  end

  @doc "Queue enrichable nodes belonging to `file_path` in `graph`."
  @spec enqueue_file(Graph.t(), String.t()) :: :ok
  def enqueue_file(graph, file_path) do
    GenServer.cast(__MODULE__, {:enqueue_file, graph, file_path})
  end

  @doc "Force-enrich a single node immediately. Blocks until complete."
  @spec enrich_now(String.t(), Graph.t()) :: {:ok, map()} | {:error, term()}
  def enrich_now(node_id, graph) do
    GenServer.call(__MODULE__, {:enrich_now, node_id, graph}, @ollama_timeout + 5_000)
  end

  @doc "Pause background processing."
  @spec pause() :: :ok
  def pause, do: GenServer.cast(__MODULE__, :pause)

  @doc "Resume background processing."
  @spec resume() :: :ok
  def resume, do: GenServer.cast(__MODULE__, :resume)

  @doc "Current queue depth, enriched count, and running status."
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  # ----------------------------------------------------------------
  # GenServer init
  # ----------------------------------------------------------------

  @impl true
  def init(_) do
    schedule_tick()
    {:ok, %{queue: :queue.new(), paused: false, processed: 0, errors: 0}}
  end

  # ----------------------------------------------------------------
  # Casts
  # ----------------------------------------------------------------

  @impl true
  def handle_cast({:enqueue_graph, graph}, state) do
    node_ids = enrichable_ids(graph)
    {:noreply, %{state | queue: enqueue_new(state.queue, node_ids)}}
  end

  @impl true
  def handle_cast({:enqueue_file, graph, file_path}, state) do
    node_ids =
      Graph.vertices(graph)
      |> Enum.filter(fn vid ->
        case CG.get_label(graph, vid) do
          %{type: t, file: ^file_path} when t in @enrichable_types -> true
          _ -> false
        end
      end)

    {:noreply, %{state | queue: enqueue_new(state.queue, node_ids)}}
  end

  @impl true
  def handle_cast(:pause, state), do: {:noreply, %{state | paused: true}}
  @impl true
  def handle_cast(:resume, state), do: {:noreply, %{state | paused: false}}

  # ----------------------------------------------------------------
  # Calls
  # ----------------------------------------------------------------

  @impl true
  def handle_call(:status, _from, state) do
    queue_depth = :queue.len(state.queue)

    {:reply,
     %{
       queue_depth: queue_depth,
       enriched: EnrichmentStore.size(),
       processed: state.processed,
       errors: state.errors,
       paused: state.paused,
       dreaming: not state.paused and queue_depth > 0
     }, state}
  end

  @impl true
  def handle_call({:enrich_now, node_id, graph}, _from, state) do
    cfg = load_config()
    result = do_enrich(node_id, graph, cfg)
    {:reply, result, state}
  end

  # ----------------------------------------------------------------
  # Tick — the background processing loop
  # ----------------------------------------------------------------

  @impl true
  def handle_info(:tick, %{paused: true} = state) do
    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    cfg = load_config()
    concurrency = Map.get(cfg, "concurrency", 4)

    {batch, remaining_queue} = dequeue_batch(state.queue, concurrency)

    {n_ok, n_err} =
      if batch == [] do
        {0, 0}
      else
        Logger.debug("[Dream] Enriching #{length(batch)} node(s)")

        Task.async_stream(
          batch,
          fn {node_id, graph} -> do_enrich(node_id, graph, cfg) end,
          max_concurrency: concurrency,
          timeout: @ollama_timeout,
          on_timeout: :kill_task
        )
        |> Enum.reduce({0, 0}, fn
          {:ok, {:ok, _}}, {ok, err} -> {ok + 1, err}
          {:ok, {:error, _}}, {ok, err} -> {ok, err + 1}
          {:exit, _}, {ok, err} -> {ok, err + 1}
        end)
      end

    schedule_tick()

    {:noreply,
     %{
       state
       | queue: remaining_queue,
         processed: state.processed + n_ok,
         errors: state.errors + n_err
     }}
  end

  # ----------------------------------------------------------------
  # Core enrichment logic
  # ----------------------------------------------------------------

  defp do_enrich(node_id, graph, cfg) do
    if EnrichmentStore.enriched?(node_id) do
      {:ok, EnrichmentStore.get(node_id)}
    else
      case CG.get_label(graph, node_id) do
        nil ->
          {:error, :node_not_found}

        meta ->
          source = read_source(meta)
          prompt = build_prompt(meta, source)

          case call_ollama(prompt, cfg) do
            {:ok, enrichment} ->
              enrichment =
                Map.put(enrichment, "enriched_at", DateTime.utc_now() |> DateTime.to_iso8601())

              EnrichmentStore.put(node_id, enrichment)
              Neo4j.update_enrichment(node_id, enrichment)
              re_embed(node_id, meta, enrichment)
              {:ok, enrichment}

            {:error, _} = err ->
              err
          end
      end
    end
  end

  defp build_prompt(meta, source) do
    type = Map.get(meta, :type, "node")
    name = Map.get(meta, :name, "unknown")
    file = Map.get(meta, :file, "") |> Path.basename()

    """
    You are a code analyst. Analyze this #{type} named `#{name}` from `#{file}`.

    Source:
    ```
    #{source}
    ```

    Respond with ONLY valid JSON (no markdown, no explanation):
    {
      "summary": "one sentence: what this #{String.downcase(type)} does",
      "domain": "one of: auth, data, ui, api, config, infra, util, test",
      "tags": ["2-5 short keyword tags"],
      "complexity": "one of: low, medium, high"
    }
    """
  end

  defp call_ollama(prompt, cfg) do
    url = Map.get(cfg, "url", "http://localhost:11434")
    model = Map.get(cfg, "model", "qwen3:8b")

    body = %{
      model: model,
      prompt: prompt,
      stream: false,
      options: %{temperature: 0.1}
    }

    case Req.post("#{url}/api/generate", json: body, receive_timeout: @ollama_timeout) do
      {:ok, %{status: 200, body: %{"response" => text}}} ->
        parse_json_response(text)

      {:ok, %{status: status, body: body}} ->
        {:error, "Ollama #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Ollama unreachable: #{inspect(reason)}"}
    end
  end

  defp parse_json_response(text) do
    # Strip any accidental markdown fences the model may add
    cleaned =
      text
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, {:bad_json, text}}
    end
  end

  # After enrichment, re-embed using the richer text so semantic search improves.
  defp re_embed(node_id, meta, enrichment) do
    text = enriched_node_text(meta, enrichment)
    DirGraph.RAG.index_node(node_id, text)
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp enrichable_ids(graph) do
    Graph.vertices(graph)
    |> Enum.filter(fn vid ->
      case CG.get_label(graph, vid) do
        %{type: t} when t in @enrichable_types -> true
        _ -> false
      end
    end)
    |> Enum.reject(&EnrichmentStore.enriched?/1)
  end

  # Adds up to `n` new node_ids to the queue, pairing each with the current
  # Server graph snapshot so the worker has source access without a GenServer call.
  defp enqueue_new(queue, node_ids) do
    graph = DirGraph.Server.get_graph()

    Enum.reduce(node_ids, queue, fn node_id, q ->
      if EnrichmentStore.enriched?(node_id) or already_queued?(q, node_id) do
        q
      else
        :queue.in({node_id, graph}, q)
      end
    end)
  end

  defp already_queued?(queue, node_id) do
    :queue.to_list(queue) |> Enum.any?(fn {id, _} -> id == node_id end)
  end

  defp dequeue_batch(queue, n) do
    Enum.reduce_while(1..n, {[], queue}, fn _, {batch, q} ->
      case :queue.out(q) do
        {{:value, item}, rest} -> {:cont, {[item | batch], rest}}
        {:empty, _} -> {:halt, {batch, q}}
      end
    end)
    |> then(fn {batch, q} -> {Enum.reverse(batch), q} end)
  end

  defp read_source(%{file: file, line: line} = meta) when is_binary(file) do
    end_line = Map.get(meta, :end_line, line)

    case File.read(file) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.slice((line - 1)..(end_line - 1))
        |> Enum.join("\n")

      _ ->
        ""
    end
  end

  defp read_source(_), do: ""

  defp enriched_node_text(meta, enrichment) do
    type = Map.get(meta, :type, "node")
    name = Map.get(meta, :name, "")
    summary = Map.get(enrichment, "summary", "")
    domain = Map.get(enrichment, "domain", "")
    tags = Map.get(enrichment, "tags", []) |> Enum.join(", ")
    source = read_source(meta)

    "#{type} #{name}\n#{summary}\ndomain: #{domain}, tags: #{tags}\n#{source}"
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp load_config do
    with true <- File.exists?(@config_path),
         {:ok, raw} <- File.read(@config_path),
         {:ok, decoded} <- Jason.decode(raw) do
      cfg = Map.get(decoded, "dream", %{})

      Map.merge(
        %{"model" => "qwen3:8b", "concurrency" => 4, "url" => "http://localhost:11434"},
        cfg
      )
    else
      _ -> %{"model" => "qwen3:8b", "concurrency" => 4, "url" => "http://localhost:11434"}
    end
  end
end
