defmodule PtcRunner.TestSupport.OpenAICompatLLMGateway do
  @moduledoc false

  alias PtcRunner.TestSupport.MCPHTTPFixture

  @spec start((map() -> term())) :: %{port: :inet.port_number(), close: (-> :ok)}
  def start(handler) when is_function(handler, 1) do
    fixture = MCPHTTPFixture.start(handler)
    %URI{port: port} = URI.parse(fixture.endpoint)
    %{port: port, close: fixture.close}
  end

  @spec selector(:inet.port_number(), String.t()) :: String.t()
  def selector(port, model \\ "local-model") when is_integer(port) and is_binary(model) do
    "openai-compat:http://127.0.0.1:#{port}/v1|#{model}"
  end

  @spec json_completion(String.t(), map()) :: {200, [{String.t(), String.t()}], String.t()}
  def json_completion(content, usage \\ %{}) do
    body =
      Jason.encode!(%{
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => content}
          }
        ],
        "usage" => usage_object(usage)
      })

    {200, [{"content-type", "application/json"}], body}
  end

  @spec json_tool_call(String.t(), String.t(), map(), map()) ::
          {200, [{String.t(), String.t()}], String.t()}
  def json_tool_call(id, name, args, usage \\ %{}) do
    body =
      Jason.encode!(%{
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => id,
                  "type" => "function",
                  "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
                }
              ]
            }
          }
        ],
        "usage" => usage_object(usage)
      })

    {200, [{"content-type", "application/json"}], body}
  end

  @spec sse_text([String.t()], map() | nil) :: {:script, (:gen_tcp.socket() -> :ok)}
  def sse_text(deltas, usage \\ nil) when is_list(deltas) do
    sse_script(
      deltas,
      event(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]}) <>
        usage_event(usage)
    )
  end

  # Minimized OpenRouter terminal sequence: finish, then a usage event that
  # repeats the empty index-zero terminal choice instead of `choices: []`.
  @spec sse_openrouter_terminal_text([String.t()], map()) ::
          {:script, (:gen_tcp.socket() -> :ok)}
  def sse_openrouter_terminal_text(deltas, usage) when is_list(deltas) and is_map(usage) do
    sse_script(
      deltas,
      event(%{
        "choices" => [%{"index" => 0, "delta" => %{"content" => ""}, "finish_reason" => "stop"}]
      }) <>
        event(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"content" => "", "role" => "assistant"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => usage_object(usage)
        })
    )
  end

  @spec send_fixed(:gen_tcp.socket(), binary()) :: :ok
  def send_fixed(socket, body) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" <>
          "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body
      )

    await_client_close(socket)
  end

  @spec event(map()) :: String.t()
  def event(value), do: "data: " <> Jason.encode!(value) <> "\n\n"

  @spec await_client_close(:gen_tcp.socket()) :: :ok | term()
  def await_client_close(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, _bytes} -> await_client_close(socket)
      {:error, :closed} -> :ok
      error -> error
    end
  end

  defp sse_script(deltas, terminal) do
    body =
      event(%{"choices" => [%{"index" => 0, "delta" => %{"role" => "assistant"}}]}) <>
        Enum.map_join(deltas, fn delta ->
          event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => delta}}]})
        end) <>
        terminal <>
        "data: [DONE]\n\n"

    {:script, fn socket -> send_fixed(socket, body) end}
  end

  defp usage_event(nil), do: ""

  defp usage_event(usage) do
    event(%{"choices" => [], "usage" => usage_object(usage)})
  end

  defp usage_object(usage) when is_map(usage) do
    prompt = Map.get(usage, :input, Map.get(usage, "prompt_tokens", 1))
    completion = Map.get(usage, :output, Map.get(usage, "completion_tokens", 1))

    %{
      "prompt_tokens" => prompt,
      "completion_tokens" => completion,
      "total_tokens" =>
        Map.get(usage, :total, Map.get(usage, "total_tokens", prompt + completion))
    }
    |> maybe_put_cost(usage)
    |> maybe_put_cached(usage)
  end

  defp maybe_put_cost(object, usage) do
    case Map.get(usage, :total_cost) || Map.get(usage, "cost") do
      cost when is_number(cost) -> Map.put(object, "cost", cost)
      _missing -> object
    end
  end

  defp maybe_put_cached(object, usage) do
    case Map.get(usage, :cache_read) || Map.get(usage, "cached_tokens") do
      tokens when is_integer(tokens) ->
        Map.put(object, "prompt_tokens_details", %{"cached_tokens" => tokens})

      _missing ->
        object
    end
  end
end
