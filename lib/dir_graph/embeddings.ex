defmodule DirGraph.Embeddings do
  @moduledoc """
  Pluggable embedding backend for the GraphRAG layer.

  Reads configuration from the `embeddings` key in `.dir_graph/mcp_config.json`.
  If no config is present, defaults to a local Ollama server.

  ## Ollama (default)

      {
        "embeddings": {
          "backend": "ollama",
          "model": "nomic-embed-text",
          "url": "http://localhost:11434"
        }
      }

  Install: https://ollama.ai — then `ollama pull nomic-embed-text`

  ## OpenAI

      {
        "embeddings": {
          "backend": "openai",
          "model": "text-embedding-3-small",
          "api_key_env": "OPENAI_API_KEY"
        }
      }

  ## Return values

  `embed/1` returns `{:ok, [float]}` on success, `{:error, reason}` otherwise.
  The RAG layer silently skips nodes that fail to embed — a missing embedding
  means the node won't appear in semantic search results, but the graph continues
  to work normally.
  """

  @config_path ".dir_graph/mcp_config.json"

  @doc """
  Embed `text` using the configured backend.
  Returns `{:ok, vector}` or `{:error, reason}`.
  """
  @spec embed(String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed(text) when is_binary(text) and byte_size(text) > 0 do
    config  = load_config()
    backend = Map.get(config, "backend", "ollama")
    do_embed(backend, config, text)
  end

  def embed(_), do: {:error, :empty_text}

  @doc "Returns true if an embedding backend is reachable and configured."
  @spec available?() :: boolean()
  def available? do
    config  = load_config()
    backend = Map.get(config, "backend", "ollama")
    probe(backend, config)
  end

  # ----------------------------------------------------------------
  # Backends
  # ----------------------------------------------------------------

  defp do_embed("ollama", config, text) do
    url   = Map.get(config, "url", "http://localhost:11434")
    model = Map.get(config, "model", "nomic-embed-text")

    case Req.post("#{url}/api/embeddings", json: %{model: model, prompt: text}) do
      {:ok, %{status: 200, body: %{"embedding" => vector}}} ->
        {:ok, vector}

      {:ok, %{status: status, body: body}} ->
        {:error, "Ollama error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Ollama unreachable: #{inspect(reason)}"}
    end
  end

  defp do_embed("openai", config, text) do
    model   = Map.get(config, "model", "text-embedding-3-small")
    key_env = Map.get(config, "api_key_env", "OPENAI_API_KEY")
    api_key = System.get_env(key_env)

    if is_nil(api_key) or api_key == "" do
      {:error, "OpenAI API key not set in env var #{key_env}"}
    else
      case Req.post(
             "https://api.openai.com/v1/embeddings",
             json: %{model: model, input: text},
             headers: [{"Authorization", "Bearer #{api_key}"}]
           ) do
        {:ok, %{status: 200, body: %{"data" => [%{"embedding" => vector} | _]}}} ->
          {:ok, vector}

        {:ok, %{status: status, body: body}} ->
          {:error, "OpenAI error #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "OpenAI unreachable: #{inspect(reason)}"}
      end
    end
  end

  defp do_embed(backend, _config, _text) do
    {:error, "Unknown embedding backend '#{backend}'. Supported: ollama, openai"}
  end

  # Quick reachability probe — verifies Ollama is up AND the configured model is pulled.
  defp probe("ollama", config) do
    url   = Map.get(config, "url", "http://localhost:11434")
    model = Map.get(config, "model", "nomic-embed-text")

    case Req.get("#{url}/api/tags") do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        Enum.any?(models, fn m -> Map.get(m, "name") == model end)

      _ ->
        false
    end
  end

  defp probe("openai", config) do
    key_env = Map.get(config, "api_key_env", "OPENAI_API_KEY")
    api_key = System.get_env(key_env)
    not is_nil(api_key) and api_key != ""
  end

  defp probe(_, _), do: false

  # ----------------------------------------------------------------
  # Config
  # ----------------------------------------------------------------

  defp load_config do
    with true          <- File.exists?(@config_path),
         {:ok, raw}    <- File.read(@config_path),
         {:ok, decoded} <- Jason.decode(raw) do
      Map.get(decoded, "embeddings", %{})
    else
      _ -> %{}
    end
  end
end
