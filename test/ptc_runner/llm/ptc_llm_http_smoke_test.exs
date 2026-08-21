defmodule PtcRunner.LLM.PtcLlmHttpSmokeTest do
  use ExUnit.Case, async: false

  alias PtcLlmHttp.{Credential, Deadline, Error, ProcessBudget, Request, Runtime, Target}
  alias PtcLlmHttp.{StreamComplete, Usage}
  alias PtcRunner.TestSupport.MCPHTTPFixture

  @group "ptc-runner-smoke"

  test "synchronous callbacks preserve fragmented delta order and terminal usage" do
    parent = self()
    release = make_ref()
    gateway = start_gateway(release)
    runtime = runtime()
    target = target(gateway.port, %{tokens: true, cost: true})
    request = request()

    stream =
      Task.async(fn ->
        stream(runtime, target, request, fn %{delta: delta} ->
          send(parent, {:delta, delta, self()})

          if delta == "hello " do
            receive do
              {^release, :continue} -> :cont
            end
          else
            :cont
          end
        end)
      end)

    assert_receive {:gateway_request, gateway_worker, %{body: wire_request}}
    send(gateway_worker, {release, :serve_success})
    assert wire_request["model"] == "local-smoke-model"
    assert wire_request["max_tokens"] == 64
    assert wire_request["stream"] == true
    assert wire_request["stream_options"] == %{"include_usage" => true}
    assert wire_request["messages"] == [%{"role" => "user", "content" => "hello"}]

    assert_receive {:delta, "hello ", callback}
    send(gateway_worker, {release, :send_rest})
    assert_receive {^release, :rest_sent}

    # The gateway has put the rest of the response on the connection, but
    # the outstanding callback prevents the next delta from being delivered.
    assert Task.yield(stream, 0) == nil
    refute_received {:delta, "world", _callback}

    send(callback, {release, :continue})
    assert_receive {:delta, "world", ^callback}

    assert {:ok,
            %{
              done: true,
              delivered: %{bytes: 11, chunks: 2},
              tokens: %{
                input: 3,
                output: 2,
                cache_read: 1,
                total_cost: 0.125
              }
            }} = Task.await(stream, 5_000)

    assert_receive {^release, :client_closed}
    assert_released(runtime)
  end

  test "gateway disconnect while callback is blocked closes and releases before readmission" do
    parent = self()
    release = make_ref()
    gateway = start_gateway(release)
    runtime = runtime()
    target = target(gateway.port, %{tokens: false, cost: false})
    request = request()

    failed_stream =
      Task.async(fn ->
        stream(runtime, target, request, fn %{delta: delta} ->
          send(parent, {:blocked_delta, delta, self()})

          receive do
            {^release, :continue} -> :cont
          end
        end)
      end)

    assert_receive {:gateway_request, first_gateway_worker, %{body: _wire_request}}
    send(first_gateway_worker, {release, :serve_disconnect})
    assert_receive {:blocked_delta, "partial", callback}
    callback_ref = Process.monitor(callback)

    send(first_gateway_worker, {release, :disconnect})
    assert_receive {^release, :gateway_disconnected}

    assert {:ok,
            %{
              in_use: 1,
              groups: %{@group => %{in_use: 1, limit: 1}}
            }} = Runtime.snapshot(runtime)

    send(callback, {release, :continue})
    assert_receive {^release, :client_closed}

    assert {:error,
            %Error{
              kind: :connection_closed,
              phase: :receive_body,
              scope: :transport,
              dispatch: :possibly_sent
            }} = Task.await(failed_stream, 5_000)

    assert_receive {:DOWN, ^callback_ref, :process, ^callback, _reason}
    assert_released(runtime)

    admitted_stream =
      Task.async(fn ->
        stream(runtime, target, request, fn %{delta: delta} ->
          send(parent, {:admitted_delta, delta})
          :cont
        end)
      end)

    assert_receive {:gateway_request, second_gateway_worker, %{body: _wire_request}}
    send(second_gateway_worker, {release, :serve_recovery})
    assert_receive {:admitted_delta, "recovered"}

    assert {:ok,
            %{
              done: true,
              delivered: %{bytes: 9, chunks: 1},
              tokens: %{}
            }} = Task.await(admitted_stream, 5_000)

    assert_receive {^release, :second_client_closed}
    assert_released(runtime)
  end

  defp stream(runtime, target, request, callback) do
    {:ok, deadline} =
      Deadline.new(System.monotonic_time(:millisecond) + 5_000)

    {:ok, budget} = ProcessBudget.new(total_heap_words: 4_000_000)

    runtime
    |> PtcLlmHttp.stream(target, request, callback,
      credential: Credential.none(),
      deadline: deadline,
      process_budget: budget
    )
    |> normalize_stream_result()
  end

  defp normalize_stream_result({:ok, %StreamComplete{} = complete}) do
    {:ok,
     %{
       done: true,
       delivered: StreamComplete.delivered(complete),
       tokens: normalize_usage(StreamComplete.usage(complete))
     }}
  end

  defp normalize_stream_result({:error, %Error{}} = error), do: error

  defp normalize_usage(nil), do: %{}

  defp normalize_usage(%Usage{} = usage) do
    facts = Usage.facts(usage)

    [
      input: facts.prompt_tokens,
      output: facts.completion_tokens,
      cache_read: facts.cached_tokens,
      total_cost: facts.cost
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp runtime do
    start_supervised!({Runtime, max_concurrency: 1, groups: %{@group => 1}})
  end

  defp target(port, usage_guarantees) do
    {:ok, target} =
      Target.new(
        kind: :openai_compat,
        base_url: "http://127.0.0.1:#{port}/v1",
        model: "local-smoke-model",
        capacity_group: @group,
        connect_policy: :literal_loopback,
        max_encoded_request_bytes: 4_096,
        max_wire_response_bytes: 1_048_576,
        tools: true,
        streaming: true,
        structured_output: :json_schema,
        cache_mode: :unsupported,
        upstream_routing: :opaque,
        usage_guarantees: usage_guarantees
      )

    target
  end

  defp request do
    {:ok, request} =
      Request.new(messages: [%{role: :user, content: "hello"}], max_tokens: 64)

    request
  end

  defp assert_released(runtime) do
    assert {:ok,
            %{
              in_use: 0,
              limit: 1,
              groups: %{@group => %{in_use: 0, limit: 1}}
            }} = Runtime.snapshot(runtime)
  end

  defp start_gateway(release) do
    parent = self()

    fixture =
      MCPHTTPFixture.start(fn request ->
        gateway_worker = self()
        send(parent, {:gateway_request, gateway_worker, request})

        receive do
          {^release, :serve_success} ->
            {:script, &serve_success(&1, parent, release)}

          {^release, :serve_disconnect} ->
            {:script, &serve_disconnect(&1, parent, release)}

          {^release, :serve_recovery} ->
            {:script, &serve_recovery(&1, parent, release)}
        end
      end)

    on_exit(fixture.close)
    %URI{port: port} = URI.parse(fixture.endpoint)
    %{port: port}
  end

  defp serve_success(socket, parent, release) do
    first =
      event(%{"choices" => [%{"index" => 0, "delta" => %{"role" => "assistant"}}]}) <>
        event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "hello "}}]})

    rest =
      event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "world"}}]}) <>
        finish_event() <>
        event(%{
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 3,
            "completion_tokens" => 2,
            "total_tokens" => 5,
            "prompt_tokens_details" => %{"cached_tokens" => 1},
            "cost" => 0.125
          }
        }) <>
        "data: [DONE]\n\n"

    :ok = send_response_head(socket, byte_size(first) + byte_size(rest))
    :ok = send_fragments(socket, split(first, [1, 2, 7, 13]))

    receive do
      {^release, :send_rest} -> :ok
    end

    :ok = send_fragments(socket, split(rest, [3, 1, 17, 5]))
    send(parent, {release, :rest_sent})
    :ok = await_client_close(socket)
    send(parent, {release, :client_closed})
    :ok
  end

  defp serve_disconnect(socket, parent, release) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" <>
          "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
      )

    :ok =
      send_chunk(
        socket,
        event(%{
          "choices" => [%{"index" => 0, "delta" => %{"content" => "partial"}}]
        })
      )

    receive do
      {^release, :disconnect} -> :ok
    end

    :ok = :gen_tcp.shutdown(socket, :write)
    send(parent, {release, :gateway_disconnected})
    :ok = await_client_close(socket)
    send(parent, {release, :client_closed})
    :ok
  end

  defp serve_recovery(socket, parent, release) do
    body =
      event(%{
        "choices" => [%{"index" => 0, "delta" => %{"content" => "recovered"}}]
      }) <>
        finish_event() <> "data: [DONE]\n\n"

    :ok = send_response_head(socket, byte_size(body))
    :ok = send_fragments(socket, split(body, [2, 11, 1, 19]))
    :ok = await_client_close(socket)
    send(parent, {release, :second_client_closed})
    :ok
  end

  defp send_response_head(socket, content_length) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" <>
        "Content-Length: #{content_length}\r\nConnection: close\r\n\r\n"
    )
  end

  defp send_chunk(socket, bytes) do
    :gen_tcp.send(
      socket,
      Integer.to_string(byte_size(bytes), 16) <> "\r\n" <> bytes <> "\r\n"
    )
  end

  defp send_fragments(socket, fragments) do
    Enum.reduce_while(fragments, :ok, fn fragment, :ok ->
      case :gen_tcp.send(socket, fragment) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp split(bytes, sizes), do: split(bytes, sizes, [])
  defp split(<<>>, _sizes, fragments), do: Enum.reverse(fragments)
  defp split(bytes, [], fragments), do: Enum.reverse([bytes | fragments])

  defp split(bytes, [size | sizes], fragments) when byte_size(bytes) > size do
    <<fragment::binary-size(^size), rest::binary>> = bytes
    split(rest, sizes, [fragment | fragments])
  end

  defp split(bytes, _sizes, fragments), do: Enum.reverse([bytes | fragments])

  defp await_client_close(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, _unexpected_bytes} -> await_client_close(socket)
      {:error, :closed} -> :ok
      error -> error
    end
  end

  defp event(value), do: "data: " <> Jason.encode!(value) <> "\n\n"

  defp finish_event do
    event(%{
      "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
    })
  end
end
