defmodule PtcRunner.LLM.PtcLlmHttpAdapterTest do
  use ExUnit.Case, async: false

  alias PtcLlmHttp.Runtime
  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.LLM
  alias PtcRunner.LLM.PtcLlmHttpAdapter
  alias PtcRunner.LLM.PtcLlmHttpPreparedModel
  alias PtcRunner.LLM.PtcLlmHttpRuntime
  alias PtcRunner.TestSupport.OpenAICompatLLMGateway

  @secret "sk-or-test-credential-sentinel"

  setup do
    previous_runtime = Application.fetch_env(:ptc_runner, :ptc_llm_http_runtime)
    previous_adapter = Application.fetch_env(:ptc_runner, :llm_adapter)
    Application.put_env(:ptc_runner, :llm_adapter, PtcLlmHttpAdapter)

    on_exit(fn ->
      restore_env(:ptc_llm_http_runtime, previous_runtime)
      restore_env(:llm_adapter, previous_adapter)
    end)

    :ok
  end

  describe "prepare_model/1" do
    test "accepts OpenRouter selectors and redacts the prepared target" do
      assert {:ok, %PtcLlmHttpPreparedModel{} = prepared, :unavailable} =
               PtcLlmHttpAdapter.prepare_model("openrouter:deepseek/deepseek-v4-flash")

      assert inspect(prepared) == "#PtcRunner.LLM.PtcLlmHttpPreparedModel<redacted>"
      refute inspect(prepared) =~ "openrouter.ai"
      refute inspect(prepared) =~ "deepseek"
    end

    test "accepts credential-free HTTP loopback openai-compat selectors" do
      selector = OpenAICompatLLMGateway.selector(17_342)

      assert {:ok, %PtcLlmHttpPreparedModel{}, :unavailable} =
               PtcLlmHttpAdapter.prepare_model(selector)
    end

    test "accepts HTTPS hostname openai-compat selectors" do
      assert {:ok, %PtcLlmHttpPreparedModel{}, :unavailable} =
               PtcLlmHttpAdapter.prepare_model("openai-compat:https://example.com/v1|local-model")
    end

    test "rejects unsupported selectors instead of falling back to ReqLLM" do
      for selector <- [
            "ollama:local-model",
            "anthropic:claude-3-5-sonnet",
            "amazon_bedrock:anthropic.claude",
            "openai:gpt-4o",
            "openrouter:",
            "openai-compat:http://example.com/v1|model",
            "openai-compat:https://127.0.0.1/v1|model"
          ] do
        assert {:error, %ProviderError{kind: :invalid_request, retryable?: false}} =
                 PtcLlmHttpAdapter.prepare_model(selector)
      end
    end

    test "publishes OpenRouter selectors and withholds openai-compat endpoints" do
      assert PtcLlmHttpAdapter.public_model("openrouter:deepseek/deepseek-v4-flash") ==
               {:ok, "openrouter:deepseek/deepseek-v4-flash"}

      assert PtcLlmHttpAdapter.public_model(OpenAICompatLLMGateway.selector(9_001)) == :private
    end

    test "does not claim an OTP provider application" do
      assert PtcLlmHttpAdapter.provider_application("openrouter:deepseek/deepseek-v4-flash") ==
               nil
    end
  end

  describe "PtcRunner request path" do
    test "completes ordinary text through llm-request" do
      parent = self()

      gateway =
        OpenAICompatLLMGateway.start(fn request ->
          send(parent, {:served, request})
          OpenAICompatLLMGateway.json_completion("KERNEL_OK", %{input: 3, output: 2})
        end)

      on_exit(gateway.close)

      assert {:ok, %{value: %{"content" => "KERNEL_OK", "tokens" => tokens}}} =
               kernel_complete(gateway.port, %{messages: [%{role: :user, content: "ping"}]})

      assert tokens["input"] == 3
      assert tokens["output"] == 2
      assert_receive {:served, %{body: body}}
      refute body["stream"]
    end

    test "streams deltas synchronously and returns final usage" do
      parent = self()
      release = make_ref()

      gateway =
        OpenAICompatLLMGateway.start(fn request ->
          send(parent, {:gateway_request, self(), request})

          {:script,
           fn socket ->
             first =
               OpenAICompatLLMGateway.event(%{
                 "choices" => [%{"index" => 0, "delta" => %{"content" => "hello "}}]
               })

             rest =
               OpenAICompatLLMGateway.event(%{
                 "choices" => [%{"index" => 0, "delta" => %{"content" => "world"}}]
               }) <>
                 OpenAICompatLLMGateway.event(%{
                   "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
                 }) <>
                 OpenAICompatLLMGateway.event(%{
                   "choices" => [],
                   "usage" => %{
                     "prompt_tokens" => 4,
                     "completion_tokens" => 2,
                     "total_tokens" => 6
                   }
                 }) <>
                 "data: [DONE]\n\n"

             :ok =
               :gen_tcp.send(
                 socket,
                 "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" <>
                   "Content-Length: #{byte_size(first) + byte_size(rest)}\r\n" <>
                   "Connection: close\r\n\r\n" <> first
               )

             receive do
               {^release, :send_rest} -> :ok
             end

             :ok = :gen_tcp.send(socket, rest)
             OpenAICompatLLMGateway.await_client_close(socket)
           end}
        end)

      on_exit(gateway.close)

      {:ok, requester} = requester(gateway.port)

      stream =
        Task.async(fn ->
          requester.(%{
            messages: [%{role: :user, content: "hello"}],
            stream: fn %{delta: text} ->
              send(parent, {:delta, text, self()})

              if text == "hello " do
                receive do
                  {^release, :continue} -> :ok
                end
              end
            end
          })
        end)

      assert_receive {:gateway_request, worker, %{body: body}}
      assert body["stream"] == true
      refute_received {:delta, "world", _}

      send(worker, {release, :send_rest})
      assert_receive {:delta, "hello ", callback}
      refute_received {:delta, "world", _}
      send(callback, {release, :continue})
      assert_receive {:delta, "world", ^callback}

      assert {:ok, %{content: "hello world", tokens: %{input: 4, output: 2}}} =
               Task.await(stream, 5_000)
    end

    test "returns structured JSON content" do
      schema = %{
        "type" => "object",
        "properties" => %{"answer" => %{"type" => "string"}},
        "required" => ["answer"],
        "additionalProperties" => false
      }

      gateway =
        OpenAICompatLLMGateway.start(fn request ->
          assert get_in(request.body, ["response_format", "type"]) == "json_schema"
          OpenAICompatLLMGateway.json_completion(~s({"answer":"ok"}))
        end)

      on_exit(gateway.close)

      {:ok, requester} = requester(gateway.port)

      assert {:ok, %{content: content}} =
               requester.(%{
                 messages: [%{role: :user, content: "structured"}],
                 schema: schema
               })

      assert Jason.decode!(content) == %{"answer" => "ok"}
    end

    test "returns tool calls through call/2" do
      gateway =
        OpenAICompatLLMGateway.start(fn request ->
          refute request.body["stream"]
          assert is_list(request.body["tools"])
          OpenAICompatLLMGateway.json_tool_call("call_1", "lookup", %{})
        end)

      on_exit(gateway.close)

      {:ok, requester} = requester(gateway.port)

      assert {:ok, %{tool_calls: [call], content: content}} =
               requester.(%{
                 messages: [%{role: :user, content: "call it"}],
                 tools: [
                   %{
                     "type" => "function",
                     "function" => %{
                       "name" => "lookup",
                       "description" => "Lookup",
                       "parameters" => %{
                         "type" => "object",
                         "properties" => %{},
                         "additionalProperties" => false
                       }
                     }
                   }
                 ]
               })

      assert call.id == "call_1"
      assert call.name == "lookup"
      assert call.args == %{}
      assert content in [nil, ""]
    end

    test "rejects a loopback credential without logging or tracing it" do
      gateway =
        OpenAICompatLLMGateway.start(fn _request ->
          flunk("credentialed HTTP loopback must fail before connect")
        end)

      on_exit(gateway.close)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, requester} = requester(gateway.port, api_key: @secret)

          assert {:error, %ProviderError{} = error} =
                   requester.(%{messages: [%{role: :user, content: "secret"}]})

          refute inspect(error) =~ @secret
          refute error.details =~ @secret
        end)

      refute log =~ @secret
    end

    test "classifies a deadline expiry as a timeout" do
      parent = self()
      release = make_ref()

      gateway =
        OpenAICompatLLMGateway.start(fn _request ->
          send(parent, {:held, self()})

          {:script,
           fn socket ->
             receive do
               {^release, :close} -> :ok
             end

             :gen_tcp.close(socket)
           end}
        end)

      on_exit(gateway.close)

      {:ok, requester} = requester(gateway.port, receive_timeout: 50)
      caller = Task.async(fn -> requester.(%{messages: [%{role: :user, content: "hang"}]}) end)
      assert_receive {:held, worker}

      assert {:error, %ProviderError{kind: :timeout}} = Task.await(caller, 5_000)
      send(worker, {release, :close})
    end
  end

  describe "cleanup and capacity" do
    setup do
      runtime =
        start_supervised!(
          {Runtime, max_concurrency: 1, groups: %{PtcLlmHttpRuntime.capacity_group() => 1}}
        )

      Application.put_env(:ptc_runner, :ptc_llm_http_runtime, runtime)
      %{runtime: runtime}
    end

    test "releases capacity after a gateway disconnect and admits the next request", %{
      runtime: runtime
    } do
      parent = self()
      release = make_ref()

      gateway =
        OpenAICompatLLMGateway.start(fn _request ->
          send(parent, {:gateway_request, self()})

          receive do
            {^release, :serve_disconnect} ->
              {:script, &serve_disconnect(&1, parent, release)}

            {^release, :serve_recovery} ->
              OpenAICompatLLMGateway.sse_text(["recovered"])
          end
        end)

      on_exit(gateway.close)
      {:ok, requester} = requester(gateway.port)

      failed =
        Task.async(fn ->
          requester.(%{
            messages: [%{role: :user, content: "hold"}],
            stream: fn %{delta: delta} ->
              send(parent, {:blocked_delta, delta, self()})

              receive do
                {^release, :continue} -> :ok
              end
            end
          })
        end)

      assert_receive {:gateway_request, first_worker}
      send(first_worker, {release, :serve_disconnect})
      assert_receive {:blocked_delta, "partial", callback}
      callback_ref = Process.monitor(callback)

      assert {:ok, %{in_use: 1}} = Runtime.snapshot(runtime)
      send(first_worker, {release, :disconnect})
      assert_receive {^release, :gateway_disconnected}
      send(callback, {release, :continue})

      assert {:error, %ProviderError{kind: :transport_error}} = Task.await(failed, 5_000)
      assert_receive {:DOWN, ^callback_ref, :process, ^callback, _reason}
      assert_released(runtime)

      recovered =
        Task.async(fn ->
          requester.(%{
            messages: [%{role: :user, content: "again"}],
            stream: fn %{delta: delta} ->
              send(parent, {:admitted_delta, delta})
              :ok
            end
          })
        end)

      assert_receive {:gateway_request, second_worker}
      send(second_worker, {release, :serve_recovery})
      assert_receive {:admitted_delta, "recovered"}
      assert {:ok, %{content: "recovered"}} = Task.await(recovered, 5_000)
      assert_released(runtime)
    end

    test "releases capacity after a stream callback failure", %{runtime: runtime} do
      parent = self()
      release = make_ref()

      gateway =
        OpenAICompatLLMGateway.start(fn _request ->
          send(parent, {:gateway_request, self()})

          {:script,
           fn socket ->
             OpenAICompatLLMGateway.send_fixed(
               socket,
               OpenAICompatLLMGateway.event(%{
                 "choices" => [%{"index" => 0, "delta" => %{"content" => "partial"}}]
               })
             )
           end}
        end)

      on_exit(gateway.close)
      {:ok, requester} = requester(gateway.port)

      failed =
        Task.async(fn ->
          requester.(%{
            messages: [%{role: :user, content: "boom"}],
            stream: fn %{delta: _delta} ->
              send(parent, {:callback_running, self()})

              receive do
                {^release, :fail} -> raise "callback exploded"
              end
            end
          })
        end)

      assert_receive {:gateway_request, _worker}
      assert_receive {:callback_running, callback}
      send(callback, {release, :fail})

      assert {:error, %ProviderError{kind: :internal}} = Task.await(failed, 5_000)
      assert_released(runtime)
    end

    test "releases capacity after the caller dies during a blocked callback", %{runtime: runtime} do
      parent = self()
      release = make_ref()

      gateway =
        OpenAICompatLLMGateway.start(fn _request ->
          send(parent, {:gateway_request, self()})

          receive do
            {^release, :serve_hold} ->
              OpenAICompatLLMGateway.sse_text(["hold"])

            {^release, :serve_recovery} ->
              OpenAICompatLLMGateway.sse_text(["recovered"])
          end
        end)

      on_exit(gateway.close)
      {:ok, requester} = requester(gateway.port)

      caller =
        Task.async(fn ->
          requester.(%{
            messages: [%{role: :user, content: "cancel"}],
            stream: fn %{delta: _delta} ->
              send(parent, {:blocked, self()})

              receive do
                {^release, :never} -> :ok
              end
            end
          })
        end)

      assert_receive {:gateway_request, first_worker}
      send(first_worker, {release, :serve_hold})
      assert_receive {:blocked, _callback}
      assert {:ok, %{in_use: 1}} = Runtime.snapshot(runtime)
      Process.exit(caller.pid, :kill)
      ref = Process.monitor(caller.pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}

      recovered =
        Task.async(fn ->
          requester.(%{
            messages: [%{role: :user, content: "again"}],
            stream: fn %{delta: delta} ->
              send(parent, {:admitted_delta, delta})
              :ok
            end
          })
        end)

      assert_receive {:gateway_request, second_worker}
      send(second_worker, {release, :serve_recovery})
      assert_receive {:admitted_delta, "recovered"}
      assert {:ok, %{content: "recovered"}} = Task.await(recovered, 5_000)
      assert_released(runtime)
    end
  end

  defp kernel_complete(port, request) do
    {:ok, requester} = requester(port)
    {:ok, capability} = LLMCapability.new(requester: requester)
    {:ok, component} = Library.component("llm")
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(run_duration_ms: 5_000, workflow_timeout_ms: 5_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "ptc-llm-http")
    on_exit(fn -> EventSink.stop(sink) end)

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    content = request.messages |> List.first() |> Map.fetch!(:content)

    Kernel.run(
      ~s|(return (llm/request {"messages" [{"role" "user" "content" #{Jason.encode!(content)}}]}))|,
      config
    )
  end

  defp requester(port, opts \\ []) do
    LLM.callback(
      OpenAICompatLLMGateway.selector(port),
      Keyword.put(opts, :adapter, PtcLlmHttpAdapter)
    )
  end

  defp assert_released(runtime) do
    assert {:ok, %{in_use: 0, groups: groups}} = Runtime.snapshot(runtime)
    assert groups[PtcLlmHttpRuntime.capacity_group()].in_use == 0
  end

  defp serve_disconnect(socket, parent, release) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" <>
          "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
      )

    chunk =
      OpenAICompatLLMGateway.event(%{
        "choices" => [%{"index" => 0, "delta" => %{"content" => "partial"}}]
      })

    :ok =
      :gen_tcp.send(
        socket,
        Integer.to_string(byte_size(chunk), 16) <> "\r\n" <> chunk <> "\r\n"
      )

    receive do
      {^release, :disconnect} -> :ok
    end

    :ok = :gen_tcp.shutdown(socket, :write)
    send(parent, {release, :gateway_disconnected})
    OpenAICompatLLMGateway.await_client_close(socket)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:ptc_runner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:ptc_runner, key)
end
