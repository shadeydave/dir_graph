defmodule DirGraph.LSP.Client do
  @moduledoc """
  Synchronous LSP client over a spawned subprocess's stdio.

  LSP uses the same JSON-RPC 2.0 wire format as MCP, framed with
  HTTP-style Content-Length headers:

      Content-Length: 123\r\n\r\n{"jsonrpc":"2.0",...}

  The client buffers all port output, parses complete frames, and blocks
  the caller until the response matching a given request ID arrives.
  Notifications and other out-of-order messages are discarded.

  Designed for sequential use — start, extract symbols from N files, stop.
  Not safe for concurrent calls on the same client struct.
  """

  defstruct [:port, :next_id, :buffer]

  @timeout_ms 15_000

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  @doc """
  Spawns `cmd` with `args`, performs the LSP initialize handshake,
  and returns `{:ok, client}` or `{:error, reason}`.
  """
  def start(cmd, args, root_path) do
    case System.find_executable(cmd) do
      nil ->
        {:error, {:not_found, cmd}}

      executable ->
        port =
          Port.open(
            {:spawn_executable, executable},
            [:binary, {:args, args}, :exit_status]
          )

        client = %__MODULE__{port: port, next_id: 1, buffer: ""}

        case initialize(client, root_path) do
          {:ok, client} -> {:ok, client}
          {:error, reason} ->
            Port.close(port)
            {:error, reason}
        end
    end
  end

  @doc """
  Sends `textDocument/didOpen` + `textDocument/documentSymbol` for `file_path`.
  Returns `{:ok, symbols, updated_client}` where `symbols` is a list of
  LSP DocumentSymbol maps (possibly nested via "children").
  """
  def document_symbols(%__MODULE__{} = client, file_path) do
    uri = file_uri(file_path)

    client =
      send_notification(client, "textDocument/didOpen", %{
        textDocument: %{
          uri: uri,
          languageId: language_id_for(file_path),
          version: 1,
          text: File.read!(file_path)
        }
      })

    {client, id} = alloc_id(client)

    client =
      send_request(client, id, "textDocument/documentSymbol", %{
        textDocument: %{uri: uri}
      })

    case await_id(client, id) do
      {:ok, result, client} ->
        client = send_notification(client, "textDocument/didClose", %{
          textDocument: %{uri: uri}
        })
        {:ok, result || [], client}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Sends shutdown + exit and closes the port."
  def stop(%__MODULE__{port: port} = client) do
    try do
      {client, id} = alloc_id(client)
      client = send_request(client, id, "shutdown", %{})
      {_result, client} = await_id(client, id)
      send_notification(client, "exit", %{})
    after
      Port.close(port)
    end

    :ok
  end

  # ----------------------------------------------------------------
  # Handshake
  # ----------------------------------------------------------------

  defp initialize(client, root_path) do
    {client, id} = alloc_id(client)

    client =
      send_request(client, id, "initialize", %{
        processId: :os.getpid(),
        rootUri: file_uri(root_path),
        capabilities: %{
          textDocument: %{
            documentSymbol: %{hierarchicalDocumentSymbolSupport: true}
          }
        }
      })

    case await_id(client, id) do
      {:ok, _result, client} ->
        client = send_notification(client, "initialized", %{})
        {:ok, client}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ----------------------------------------------------------------
  # Messaging
  # ----------------------------------------------------------------

  defp alloc_id(%{next_id: n} = client), do: {%{client | next_id: n + 1}, n}

  defp send_request(%{port: port} = client, id, method, params) do
    msg = Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params})
    Port.command(port, frame(msg))
    client
  end

  defp send_notification(%{port: port} = client, method, params) do
    msg = Jason.encode!(%{jsonrpc: "2.0", method: method, params: params})
    Port.command(port, frame(msg))
    client
  end

  defp frame(msg), do: "Content-Length: #{byte_size(msg)}\r\n\r\n#{msg}"

  # ----------------------------------------------------------------
  # Response awaiting
  # ----------------------------------------------------------------

  defp await_id(client, target_id) do
    deadline = System.monotonic_time(:millisecond) + @timeout_ms
    do_await(client, target_id, deadline)
  end

  # Try to parse a complete frame from the buffer first.
  # Only block on the port if the buffer doesn't have a full message yet.
  defp do_await(%{buffer: buf} = client, target_id, deadline) do
    case parse_frame(buf) do
      {:ok, msg, rest} ->
        client = %{client | buffer: rest}

        cond do
          # Our response
          Map.get(msg, "id") == target_id and not Map.has_key?(msg, "error") ->
            {:ok, Map.get(msg, "result"), client}

          # Error response for our request
          Map.get(msg, "id") == target_id ->
            {:error, get_in(msg, ["error", "message"]) || "LSP error"}

          # Notification or unrelated response — discard and keep waiting
          true ->
            do_await(client, target_id, deadline)
        end

      :incomplete ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:error, :timeout}
        else
          receive do
            {port, {:data, data}} when port == client.port ->
              do_await(%{client | buffer: buf <> data}, target_id, deadline)

            {port, {:exit_status, code}} when port == client.port ->
              {:error, {:server_exit, code}}
          after
            remaining -> {:error, :timeout}
          end
        end
    end
  end

  # ----------------------------------------------------------------
  # Frame parsing
  # ----------------------------------------------------------------

  defp parse_frame(buf) do
    case :binary.split(buf, "\r\n\r\n") do
      [_] ->
        :incomplete

      [header, rest] ->
        case Regex.run(~r/Content-Length:\s*(\d+)/i, header) do
          [_, len_str] ->
            len = String.to_integer(len_str)

            if byte_size(rest) >= len do
              <<json::binary-size(len), remaining::binary>> = rest

              case Jason.decode(json) do
                {:ok, msg} -> {:ok, msg, remaining}
                _ -> :incomplete
              end
            else
              :incomplete
            end

          nil ->
            :incomplete
        end
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp file_uri(path), do: "file://#{Path.expand(path)}"

  defp language_id_for(path) do
    case Path.extname(path) do
      ".js" -> "javascript"
      ".jsx" -> "javascriptreact"
      ".ts" -> "typescript"
      ".tsx" -> "typescriptreact"
      ".py" -> "python"
      ".rb" -> "ruby"
      ".go" -> "go"
      ".rs" -> "rust"
      _ -> "plaintext"
    end
  end
end
