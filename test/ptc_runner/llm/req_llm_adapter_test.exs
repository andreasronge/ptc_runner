defmodule PtcRunner.LLM.ReqLLMAdapterTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.LLM.ReqLLMAdapter
  alias PtcRunner.TestSupport.TestHelpers
  alias ReqLLM.Message
  alias ReqLLM.ToolCall

  @openrouter_model "openrouter:anthropic/claude-haiku-4.5"

  setup_all do
    initially_started = Application.started_applications() |> MapSet.new(&elem(&1, 0))
    {:ok, started} = Application.ensure_all_started(:req_llm)
    :ok = ReqLLMAdapter.ensure_ready()

    on_exit(fn ->
      started
      |> Enum.reverse()
      |> Enum.reject(&MapSet.member?(initially_started, &1))
      |> Enum.each(&Application.stop/1)
    end)
  end

  describe "generate_object/4" do
    test "returns structured_output_not_supported for ollama" do
      assert {:error, :structured_output_not_supported} =
               ReqLLMAdapter.generate_object("ollama:model", [], %{})
    end

    test "returns structured_output_not_supported for openai-compat" do
      assert {:error, :structured_output_not_supported} =
               ReqLLMAdapter.generate_object("openai-compat:http://localhost|model", [], %{})
    end
  end

  describe "generate_object!/4" do
    test "raises for ollama" do
      assert_raise RuntimeError, ~r/structured_output_not_supported/, fn ->
        ReqLLMAdapter.generate_object!("ollama:model", [], %{})
      end
    end

    test "raises for openai-compat" do
      assert_raise RuntimeError, ~r/structured_output_not_supported/, fn ->
        ReqLLMAdapter.generate_object!("openai-compat:http://localhost|model", [], %{})
      end
    end
  end

  describe "generate_with_tools/4" do
    test "returns tool_calling_not_supported for ollama" do
      assert {:error, :tool_calling_not_supported} =
               ReqLLMAdapter.generate_with_tools("ollama:model", [], [])
    end

    test "returns tool_calling_not_supported for openai-compat" do
      assert {:error, :tool_calling_not_supported} =
               ReqLLMAdapter.generate_with_tools("openai-compat:http://localhost|model", [], [])
    end
  end

  describe "call/2" do
    test "keeps a local adapter tool limitation distinct from model rejection" do
      assert {:error,
              %ProviderError{
                kind: :invalid_request,
                details: "LLM adapter route does not support tool calling",
                retryable?: false
              }} =
               ReqLLMAdapter.call("ollama:model", %{
                 system: "test",
                 messages: [],
                 tools: [%{"type" => "function"}]
               })
    end

    test "classifies a permanent ReqLLM HTTP failure and retains its provider message" do
      provider_message = "Grok 4 Fast is deprecated. xAI recommends switching to Grok 4.3"

      assert {:error,
              %ProviderError{
                kind: :not_found,
                details: details,
                retryable?: false
              }} =
               call_http_failure(404, provider_message)

      assert details =~ "HTTP 404"
      assert details =~ provider_message
      refute details =~ "private prompt sentinel"
    end

    test "classifies OpenRouter's tool-bearing 404 as unsupported tool calling" do
      provider_message = "No endpoints found that support tool use. Try disabling f."

      plug = fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => %{"message" => provider_message, "code" => 404}})
      end

      request =
        Map.put(request(plug), :tools, [
          %{
            "type" => "function",
            "function" => %{
              "name" => "f",
              "description" => "fixture",
              "parameters" => %{"type" => "object", "properties" => %{}}
            }
          }
        ])

      assert {:error,
              %ProviderError{
                kind: :tool_calling_unsupported,
                details: details,
                retryable?: false
              }} = ReqLLMAdapter.call(@openrouter_model, request)

      assert details =~ provider_message
    end

    test "derives retryability from the HTTP status when ReqLLM does not classify it" do
      cases = [
        {400, :invalid_request, false},
        {401, :authentication_failed, false},
        {402, :payment_required, false},
        {403, :denied, false},
        {408, :timeout, true},
        {409, :invalid_request, true},
        {425, :invalid_request, true},
        {429, :rate_limited, true},
        {503, :unavailable, true}
      ]

      for {status, kind, retryable?} <- cases do
        assert {:error,
                %ProviderError{
                  kind: ^kind,
                  details: details,
                  retryable?: ^retryable?
                }} = call_http_failure(status, "provider failure #{status}")

        assert details =~ "HTTP #{status}"
        assert details =~ "provider failure #{status}"
      end
    end

    test "classifies a wrapped ReqLLM transport timeout as retryable" do
      plug = fn conn -> Req.Test.transport_error(conn, :timeout) end

      assert {:error,
              %ProviderError{
                kind: :timeout,
                retryable?: true
              }} = ReqLLMAdapter.call(@openrouter_model, request(plug))
    end

    test "routes schema mode to generate_object for ollama" do
      req = %{
        system: "You are helpful",
        messages: [%{role: :user, content: "test"}],
        schema: %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}
      }

      assert {:error,
              %ProviderError{
                kind: :invalid_request,
                details: "LLM provider does not support structured output",
                retryable?: false
              }} = ReqLLMAdapter.call("ollama:test", req)
    end

    test "routes text mode to generate_text" do
      req = %{
        system: "You are helpful",
        messages: [%{role: :user, content: "test"}],
        cache: false
      }

      # A contained connection failure confirms routing to generate_text and
      # classification at the adapter boundary.
      assert {:error, %ProviderError{}} = ReqLLMAdapter.call("ollama:test", req)
    end
  end

  describe "private inspection" do
    test "records the classified provider message instead of the generic fallback" do
      provider_message = "Grok 4 Fast is deprecated. xAI recommends switching to Grok 4.3"

      plug = fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => %{"message" => provider_message, "code" => 404}})
      end

      requester = fn request ->
        request
        |> ProviderRegistry.adapter_request()
        |> Map.merge(provider_options(plug))
        |> then(&ReqLLMAdapter.call(@openrouter_model, &1))
      end

      {:ok, capability} = LLMCapability.new(requester: requester)
      {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
      {:ok, state} = RunState.start(Limits.defaults())

      {:ok, inspection_sink} =
        InspectionSink.start(run_id: "llm-provider-error", trace_id: "llm-provider-error-trace")

      assert %{
               status: :error,
               kind: :provider_error,
               reason: :not_found,
               details: details,
               retryable?: false
             } =
               Dispatcher.dispatch(
                 state,
                 :workflow,
                 environment,
                 capability.name,
                 %{
                   "messages" => [
                     %{"role" => "user", "content" => "private prompt sentinel"}
                   ]
                 },
                 TestHelpers.dispatch_context(state, :workflow, 1_000),
                 nil,
                 inspection_sink
               )

      assert details =~ provider_message
      assert {:ok, records} = InspectionSink.records(inspection_sink)

      assert Enum.any?(records, fn record ->
               record["record_type"] == "capability-output" and
                 get_in(record, ["payload", "result", "details"]) == details and
                 get_in(record, ["payload", "result", "retryable?"]) == false
             end)
    end
  end

  describe "available?/1" do
    test "returns boolean for cloud providers" do
      assert is_boolean(ReqLLMAdapter.available?("openrouter:anthropic/claude-haiku-4.5"))
    end
  end

  describe "requires_api_key?/1" do
    test "returns false for ollama" do
      refute ReqLLMAdapter.requires_api_key?("ollama:model")
    end

    test "returns false for openai-compat" do
      refute ReqLLMAdapter.requires_api_key?("openai-compat:http://localhost|model")
    end

    test "returns true for cloud providers" do
      assert ReqLLMAdapter.requires_api_key?("openrouter:model")
    end
  end

  describe "embed/3" do
    test "embed! raises on connection error" do
      assert_raise RuntimeError, ~r/Embedding error/, fn ->
        ReqLLMAdapter.embed!("ollama:nomic-embed-text", "hello",
          ollama_base_url: "http://localhost:1"
        )
      end
    end
  end

  describe "stream/3" do
    test "returns error for ollama" do
      assert {:error, :streaming_not_supported} =
               ReqLLMAdapter.stream("ollama:model", %{system: "test", messages: []}, fn _ ->
                 :ok
               end)
    end

    test "returns error for openai-compat" do
      assert {:error, :streaming_not_supported} =
               ReqLLMAdapter.stream(
                 "openai-compat:http://localhost|model",
                 %{
                   system: "test",
                   messages: []
                 },
                 fn _ -> :ok end
               )
    end
  end

  # --- Pure transformers (network-free): prompt-cache activation & token/cost accounting ---

  describe "apply_caching/3 — Anthropic direct" do
    test "turns on anthropic_prompt_cache with 5m ttl and leaves messages unchanged" do
      messages = [%{role: :user, content: "hi"}]

      assert {^messages, opts} =
               ReqLLMAdapter.apply_caching("anthropic:claude-3-5-sonnet", messages, true)

      assert opts == [
               provider_options: [
                 anthropic_prompt_cache: true,
                 anthropic_prompt_cache_ttl: "5m"
               ]
             ]
    end
  end

  describe "apply_caching/3 — OpenRouter Anthropic" do
    test "pins the Anthropic provider and stamps cache_control on the last system message" do
      messages = [
        %{role: :system, content: "sys"},
        %{role: :user, content: "hi"}
      ]

      assert {cached_messages, opts} =
               ReqLLMAdapter.apply_caching(
                 "openrouter:anthropic/claude-3.5-sonnet",
                 messages,
                 true
               )

      # Pins provider routing to Anthropic with no fallbacks (so caching is honored).
      assert opts == [
               openrouter_provider: %{order: ["Anthropic"], allow_fallbacks: false}
             ]

      # Messages are rewritten to %Message{} structs; the (last) system message
      # carries the ephemeral cache_control marker.
      [system_msg, user_msg] = cached_messages
      assert %Message{role: :system, content: [system_part]} = system_msg
      assert system_part.text == "sys"
      assert system_part.metadata == %{cache_control: %{type: "ephemeral"}}

      assert %Message{role: :user, content: [user_part]} = user_msg
      assert user_part.text == "hi"
      assert user_part.metadata == %{}
    end

    test "matches via the 'claude' substring even without 'anthropic'" do
      messages = [%{role: :user, content: "hi"}]

      assert {_messages, opts} =
               ReqLLMAdapter.apply_caching("openrouter:some/claude-model", messages, true)

      assert Keyword.has_key?(opts, :openrouter_provider)
    end
  end

  describe "apply_caching/3 — Bedrock" do
    test "enables anthropic_prompt_cache for bedrock models, messages unchanged" do
      messages = [%{role: :user, content: "hi"}]

      assert {^messages, opts} =
               ReqLLMAdapter.apply_caching("amazon_bedrock:anthropic.claude-x", messages, true)

      assert opts == [
               provider_options: [
                 anthropic_prompt_cache: true,
                 anthropic_prompt_cache_ttl: "5m"
               ]
             ]
    end
  end

  describe "apply_caching/3 — non-cacheable / disabled" do
    test "non-cacheable provider returns empty opts and unchanged messages" do
      messages = [%{role: :user, content: "hi"}]

      assert {^messages, []} =
               ReqLLMAdapter.apply_caching("openai:gpt-4o", messages, true)
    end

    test "cache disabled returns empty opts and unchanged messages even for anthropic" do
      messages = [%{role: :system, content: "sys"}, %{role: :user, content: "hi"}]

      assert {^messages, []} =
               ReqLLMAdapter.apply_caching("anthropic:claude-3-5-sonnet", messages, false)
    end
  end

  describe "build_tokens_from_req_llm_response/2" do
    test "reads atom-keyed usage including cache read/creation and cost" do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        cache_read_input_tokens: 20,
        cache_creation_input_tokens: 10,
        total_cost: 0.5
      }

      assert ReqLLMAdapter.build_tokens_from_req_llm_response(usage, %{}) == %{
               input: 100,
               output: 50,
               cache_read: 20,
               cache_creation: 10,
               total_cost: 0.5
             }
    end

    test "reads string-keyed usage and falls back to cached_tokens for cache reads" do
      usage = %{"input_tokens" => 7, "output_tokens" => 3, "cached_tokens" => 2}

      assert ReqLLMAdapter.build_tokens_from_req_llm_response(usage, %{}) == %{
               input: 7,
               output: 3,
               cache_read: 2,
               cache_creation: 0
             }
    end

    test "derives cache_creation from provider_meta cache_write_tokens when usage omits it" do
      usage = %{input_tokens: 1}
      meta = %{"usage" => %{"prompt_tokens_details" => %{"cache_write_tokens" => 42}}}

      assert ReqLLMAdapter.build_tokens_from_req_llm_response(usage, meta) == %{
               input: 1,
               output: 0,
               cache_read: 0,
               cache_creation: 42
             }
    end

    test "defaults all fields to zero for empty usage and meta" do
      assert ReqLLMAdapter.build_tokens_from_req_llm_response(%{}, %{}) == %{
               input: 0,
               output: 0,
               cache_read: 0,
               cache_creation: 0
             }
    end
  end

  describe "build_stream_done_chunk/1" do
    test "preserves normalized cost and token usage for streamed responses" do
      usage = %{input_tokens: 12, output_tokens: 4, total_cost: 0.125}

      assert ReqLLMAdapter.build_stream_done_chunk(usage) == %{
               done: true,
               tokens: %{
                 input: 12,
                 output: 4,
                 cache_creation: 0,
                 cache_read: 0,
                 total_cost: 0.125
               }
             }
    end
  end

  describe "normalize_tool_calls/1" do
    test "decodes well-formed JSON arguments into a map" do
      tc = ToolCall.new("call_1", "get_weather", ~s({"city":"Paris"}))

      assert [%{id: "call_1", name: "get_weather", args: %{"city" => "Paris"}} = entry] =
               ReqLLMAdapter.normalize_tool_calls([tc])

      refute Map.has_key?(entry, :args_error)
    end

    test "records args_error and empty args for invalid-JSON arguments" do
      tc = ToolCall.new("call_2", "broken", "{not json")

      assert [entry] = ReqLLMAdapter.normalize_tool_calls([tc])
      assert entry.id == "call_2"
      assert entry.name == "broken"
      assert entry.args == %{}
      assert entry.args_error == "Invalid JSON arguments: {not json"
    end

    test "treats nil arguments as empty object (no error)" do
      tc = %ToolCall{id: "call_3", type: "function", function: %{name: "n", arguments: nil}}

      assert [%{id: "call_3", name: "n", args: %{}} = entry] =
               ReqLLMAdapter.normalize_tool_calls([tc])

      refute Map.has_key?(entry, :args_error)
    end
  end

  describe "build_messages/1" do
    test "prepends a plain system map when :system is present" do
      req = %{system: "sys", messages: [%{role: :user, content: "hi"}]}

      assert [
               %{role: :system, content: "sys"},
               %{role: :user, content: "hi"}
             ] = ReqLLMAdapter.build_messages(req)
    end

    test "omits the system message when :system is absent" do
      req = %{messages: [%{role: :user, content: "hi"}]}
      assert [%{role: :user, content: "hi"}] = ReqLLMAdapter.build_messages(req)
    end

    test "renders a tool-role message to a %Message{} with tool_call_id and text content" do
      req = %{
        messages: [%{role: :tool, content: "tool result", tool_call_id: "call_9"}]
      }

      assert [%Message{role: :tool, tool_call_id: "call_9", content: [part]}] =
               ReqLLMAdapter.build_messages(req)

      assert part.text == "tool result"
    end

    test "renders an assistant message carrying tool_calls to req_llm ToolCall structs" do
      req = %{
        messages: [
          %{
            role: :assistant,
            content: "thinking",
            tool_calls: [%{id: "call_9", function: %{name: "f", arguments: "{}"}}]
          }
        ]
      }

      assert [%Message{role: :assistant, content: [part], tool_calls: [tool_call]}] =
               ReqLLMAdapter.build_messages(req)

      assert part.text == "thinking"

      assert %ToolCall{id: "call_9", type: "function", function: %{name: "f", arguments: "{}"}} =
               tool_call
    end

    test "renders Kernel correction-history tool calls without losing name or arguments" do
      req = %{
        messages: [
          %{
            role: :assistant,
            content: nil,
            tool_calls: [
              %{id: "call_10", name: "run_ptc_lisp", args: %{"program" => "(return 42)"}}
            ]
          }
        ]
      }

      assert [%Message{tool_calls: [%ToolCall{} = tool_call]}] =
               ReqLLMAdapter.build_messages(req)

      assert tool_call.function == %{
               name: "run_ptc_lisp",
               arguments: ~s|{"program":"(return 42)"}|
             }
    end
  end

  defp call_http_failure(status, message) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"error" => %{"message" => message, "code" => status}})
    end

    ReqLLMAdapter.call(@openrouter_model, request(plug))
  end

  defp request(plug) do
    Map.put(
      provider_options(plug),
      :messages,
      [%{role: :user, content: "private prompt sentinel"}]
    )
  end

  defp provider_options(plug) do
    %{
      api_key: "test-openrouter-key",
      max_retries: 0,
      max_tokens: 10,
      req_http_options: [plug: plug, retry: false]
    }
  end
end
