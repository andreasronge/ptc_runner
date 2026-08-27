defmodule PtcRunner.LLM.ReqLLMAdapterRequestTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.LLM.Invocation
  alias PtcRunner.LLM.ReqLLMAdapter
  alias PtcRunner.LLM.ReqLLMPreparedModel
  alias PtcRunner.LLM.Requirements
  alias PtcRunner.TestSupport.LLMSupport
  alias PtcRunner.TestSupport.MCPHTTPFixture
  alias ReqLLM.Error.API.Timeout, as: ReqLLMTimeout

  setup do
    LLMSupport.admit_provider_application!()
    :ok
  end

  test "sends every attested inference control on the OpenRouter wire", %{test: test} do
    exact_options = %{
      max_tokens: 64,
      temperature: 0.25,
      seed: 7,
      top_p: 0.9,
      presence_penalty: -0.5,
      frequency_penalty: 0.75,
      reasoning_effort: :medium
    }

    expect_request(test, "deepseek/deepseek-v4-flash-0731")

    assert {:ok, target, _status, attestation} =
             ReqLLMAdapter.prepare_model(
               "openrouter:deepseek/deepseek-v4-flash-0731",
               Requirements.interim(exact_options)
             )

    {:ok, invocation} =
      Invocation.new(%{messages: [%{role: :user, content: "hi"}]}, false, "test", nil)

    assert {:ok, %{content: "ok", tokens: %{input: 1, output: 1}}} =
             ReqLLMAdapter.call(put_test_http_options(target, test), invocation)

    assert attestation.exact_options == exact_options
    assert_receive {:request_body, body}
    assert body["max_tokens"] == 64
    assert body["temperature"] == 0.25
    assert body["seed"] == 7
    assert body["top_p"] == 0.9
    assert body["presence_penalty"] == -0.5
    assert body["frequency_penalty"] == 0.75
    assert body["reasoning_effort"] == "medium"
  end

  test "sends every attested inference control on the direct OpenAI-compatible wire", %{
    test: test
  } do
    exact_options = %{
      max_tokens: 64,
      temperature: 0.25,
      seed: 0,
      top_p: 0.9,
      presence_penalty: -0.5,
      frequency_penalty: 0.75,
      reasoning_effort: :high
    }

    expect_request(test, "deployment")

    assert {:ok, target, :unavailable, attestation} =
             ReqLLMAdapter.prepare_model(
               "openai-compat:https://example.com/v1|deployment",
               Requirements.interim(exact_options)
             )

    {:ok, invocation} =
      Invocation.new(%{messages: [%{role: :user, content: "hi"}]}, false, "test", nil)

    assert {:ok, %{content: "ok"}} =
             ReqLLMAdapter.call(put_test_http_options(target, test), invocation)

    assert attestation.exact_options == exact_options
    assert_receive {:request_body, body}
    assert body["model"] == "deployment"
    assert body["max_tokens"] == 64
    assert body["temperature"] == 0.25
    assert body["seed"] == 0
    assert body["top_p"] == 0.9
    assert body["presence_penalty"] == -0.5
    assert body["frequency_penalty"] == 0.75
    assert body["reasoning_effort"] == "high"
  end

  test "does not invent token usage when a ReqLLM provider omits usage", %{test: test} do
    Req.Test.expect(
      test,
      request_handler(self(), "deepseek/deepseek-v4-flash-0731", usage: nil)
    )

    requirements = %{
      Requirements.interim(%{max_tokens: 64})
      | usage_guarantees: %{tokens: true, cost_currency: nil}
    }

    assert {:ok, target, _status, _attestation} =
             ReqLLMAdapter.prepare_model(
               "openrouter:deepseek/deepseek-v4-flash-0731",
               requirements
             )

    {:ok, invocation} =
      Invocation.new(%{messages: [%{role: :user, content: "hi"}]}, false, "test", nil)

    assert {:ok, %{content: "ok", tokens: tokens}} =
             ReqLLMAdapter.call(put_test_http_options(target, test), invocation)

    refute Map.has_key?(tokens, :input)
    refute Map.has_key?(tokens, :output)
  end

  test "preserves numeric and decimal-string cost on the direct OpenAI-compatible path", %{
    test: test
  } do
    assert {:ok, target, :unavailable, _attestation} =
             ReqLLMAdapter.prepare_model(
               "openai-compat:https://example.com/v1|deployment",
               Requirements.interim(%{max_tokens: 64})
             )

    {:ok, invocation} =
      Invocation.new(%{messages: [%{role: :user, content: "hi"}]}, false, "test", nil)

    for cost <- [0.25, "0.2500001"] do
      Req.Test.expect(
        test,
        request_handler(self(), "deployment",
          usage: %{
            "prompt_tokens" => 1,
            "completion_tokens" => 1,
            "total_tokens" => 2,
            "total_cost" => cost
          }
        )
      )

      assert {:ok, %{tokens: %{total_cost: ^cost}}} =
               ReqLLMAdapter.call(put_test_http_options(target, test), invocation)
    end
  end

  test "preserves an attested token-limit alias through ReqLLM dispatch", %{test: test} do
    Req.Test.expect(test, responses_request_handler(self(), "gpt-5"))

    assert {:ok, target, :cataloged, _attestation} =
             ReqLLMAdapter.prepare_model(
               "openai:gpt-5",
               Requirements.interim(%{max_tokens: 64, reasoning_effort: :high})
             )

    {:ok, invocation} =
      Invocation.new(%{messages: [%{role: :user, content: "hi"}]}, false, "test", nil)

    assert {:ok, %{content: "ok"}} =
             ReqLLMAdapter.call(put_test_http_options(target, test), invocation)

    assert_receive {:request_body, body}
    assert body["max_output_tokens"] == 64
    assert body["reasoning"] == %{"effort" => "high"}
    refute Map.has_key?(body, "max_tokens")
    refute Map.has_key?(body, "max_completion_tokens")
  end

  test "json_schema generate_object uses provider-native response_format", %{test: test} do
    schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

    expect_object_request(test, "deepseek/deepseek-v4-flash-0731", ~s({"ok":true}))

    assert {:ok, %{object: %{"ok" => true}, tokens: tokens}} =
             ReqLLMAdapter.generate_object(
               "openrouter:deepseek/deepseek-v4-flash-0731",
               [%{role: :user, content: "hi"}],
               schema,
               api_key: "test",
               req_http_options: [plug: {Req.Test, test}]
             )

    assert is_map(tokens)
    assert_receive {:request_body, body}

    assert get_in(body, ["response_format", "type"]) == "json_schema"
    assert get_in(body, ["response_format", "json_schema", "schema", "type"]) == "object"
    refute Map.has_key?(body, "tools")
    refute Map.has_key?(body, "tool_choice")
  end

  test "json_schema refuses a token budget that ReqLLM would raise on the wire" do
    assert {:error, :unsupported_model_option} =
             ReqLLMAdapter.prepare_model(
               "openrouter:deepseek/deepseek-v4-flash-0731",
               Requirements.interim(%{max_tokens: 64}, :json_schema)
             )
  end

  test "json_schema preserves the minimum admitted token budget on the wire", %{test: test} do
    schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

    expect_object_request(test, "deepseek/deepseek-v4-flash-0731", ~s({"ok":true}))

    assert {:ok, target, _status, _attestation} =
             ReqLLMAdapter.prepare_model(
               "openrouter:deepseek/deepseek-v4-flash-0731",
               Requirements.interim(%{max_tokens: 200}, :json_schema)
             )

    {:ok, invocation} =
      Invocation.new(
        %{messages: [%{role: :user, content: "hi"}], schema: schema},
        false,
        "test",
        nil
      )

    assert {:ok, %{object: %{"ok" => true}}} =
             ReqLLMAdapter.call(put_test_http_options(target, test), invocation)

    assert_receive {:request_body, body}
    assert body["max_tokens"] == 200
  end

  test "json_schema generate_object does not dispatch a tool-fallback Vertex model" do
    plug = fn _conn ->
      flunk("json_schema must not dispatch a tool-fallback Vertex request")
    end

    assert {:error, :unsupported_model_option} =
             ReqLLMAdapter.generate_object(
               "google_vertex:zai-org/glm-4.7-maas",
               [%{role: :user, content: "hi"}],
               %{
                 "type" => "object",
                 "properties" => %{"ok" => %{"type" => "boolean"}},
                 "required" => ["ok"]
               },
               api_key: "test",
               req_http_options: [plug: plug, retry: false]
             )
  end

  test "json_schema generate_object does not dispatch Azure through a synthetic tool" do
    plug = fn _conn ->
      flunk("json_schema must not dispatch an Azure tool-fallback request")
    end

    assert {:error, :unsupported_model_option} =
             ReqLLMAdapter.generate_object(
               "azure:gpt-4o",
               [%{role: :user, content: "hi"}],
               %{
                 "type" => "object",
                 "properties" => %{"ok" => %{"type" => "boolean"}},
                 "required" => ["ok"]
               },
               api_key: "test",
               req_http_options: [plug: plug, retry: false]
             )
  end

  test "json_object uses provider-native response_format and does not inject tools", %{
    test: test
  } do
    schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

    expect_request(test, "deepseek/deepseek-v4-flash-0731", content: ~s({"ok":true}))

    assert {:ok, target, _status, _attestation} =
             ReqLLMAdapter.prepare_model(
               "openrouter:deepseek/deepseek-v4-flash-0731",
               Requirements.interim(%{max_tokens: 64}, :json_object)
             )

    {:ok, invocation} =
      Invocation.new(
        %{messages: [%{role: :user, content: "hi"}], schema: schema},
        false,
        "test",
        nil
      )

    assert {:ok, %{json: ~s({"ok":true}), tokens: tokens}} =
             ReqLLMAdapter.call(put_test_http_options(target, test), invocation)

    assert is_map(tokens)
    assert_receive {:request_body, body}
    assert get_in(body, ["response_format", "type"]) == "json_object"
    refute Map.has_key?(body, "tools")
    refute Map.has_key?(body, "tool_choice")
  end

  test "an elapsed Kernel deadline is a timeout without dispatching" do
    plug = fn _conn ->
      flunk("elapsed LLM deadline must not dispatch")
    end

    schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

    assert {:ok, target, _status, _attestation} =
             ReqLLMAdapter.prepare_model(
               "openrouter:deepseek/deepseek-v4-flash-0731",
               Requirements.interim(%{max_tokens: 64}, :json_object)
             )

    {:ok, invocation} =
      Invocation.new(
        %{messages: [%{role: :user, content: "hi"}], schema: schema},
        false,
        "test",
        System.monotonic_time(:millisecond) - 1
      )

    assert {:error,
            %ProviderError{
              kind: :timeout,
              retryable?: true,
              dispatch_provenance: :not_dispatched
            }} = ReqLLMAdapter.call(put_test_http_options(target, plug), invocation)
  end

  test "a deadline expiring at final ReqLLM option assembly returns timeout" do
    deadline = System.monotonic_time(:millisecond)

    assert {:error,
            %ProviderError{
              kind: :timeout,
              retryable?: true,
              dispatch_provenance: :not_dispatched
            }} = ReqLLMAdapter.request_deadline_opts([], deadline, deadline)
  end

  test "ReqLLM whole-call timeout exceptions stay classified as timeouts" do
    timeout = ReqLLMTimeout.exception(kind: :total, timeout: 10)

    assert {:error, %ProviderError{kind: :timeout, retryable?: true}} =
             ReqLLMAdapter.normalize_provider_call({:error, timeout})
  end

  test "a live Kernel deadline still dispatches while time remains", %{test: test} do
    schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

    expect_request(test, "deepseek/deepseek-v4-flash-0731", content: ~s({"ok":true}))

    assert {:ok, target, _status, _attestation} =
             ReqLLMAdapter.prepare_model(
               "openrouter:deepseek/deepseek-v4-flash-0731",
               Requirements.interim(%{max_tokens: 64}, :json_object)
             )

    {:ok, invocation} =
      Invocation.new(
        %{messages: [%{role: :user, content: "hi"}], schema: schema},
        false,
        "test",
        System.monotonic_time(:millisecond) + 60_000
      )

    assert {:ok, %{json: ~s({"ok":true})}} =
             ReqLLMAdapter.call(put_test_http_options(target, test), invocation)
  end

  test "terminating the adapter caller also terminates the active HTTP request" do
    parent = self()
    previous_total_timeout = Application.fetch_env(:req_llm, :total_timeout)
    Application.put_env(:req_llm, :total_timeout, 5_000)

    on_exit(fn ->
      case previous_total_timeout do
        {:ok, timeout} -> Application.put_env(:req_llm, :total_timeout, timeout)
        :error -> Application.delete_env(:req_llm, :total_timeout)
      end
    end)

    plug = fn conn ->
      send(parent, {:request_started, self()})

      receive do
        :release -> Req.Test.json(conn, %{"choices" => []})
      end
    end

    assert {:ok, target, _status, _attestation} =
             ReqLLMAdapter.prepare_model(
               "openrouter:deepseek/deepseek-v4-flash-0731",
               Requirements.interim(%{max_tokens: 64}, :unsupported)
             )

    {:ok, invocation} =
      Invocation.new(
        %{messages: [%{role: :user, content: "hi"}]},
        false,
        "test",
        System.monotonic_time(:millisecond) + 5_000
      )

    caller =
      spawn(fn -> ReqLLMAdapter.call(put_test_http_options(target, plug), invocation) end)

    caller_ref = Process.monitor(caller)
    assert_receive {:request_started, request_pid}
    request_ref = Process.monitor(request_pid)

    on_exit(fn ->
      if Process.alive?(request_pid), do: send(request_pid, :release)
    end)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    assert_receive {:DOWN, ^request_ref, :process, ^request_pid, _reason}, 500
  end

  test "json_object does not dispatch Anthropic or Bedrock through OpenAI response_format" do
    plug = fn _conn ->
      flunk("json_object must not dispatch a provider that cannot honor JSON-object output")
    end

    schema = %{
      "type" => "object",
      "properties" => %{"ok" => %{"type" => "boolean"}},
      "required" => ["ok"]
    }

    for selector <- [
          "anthropic:claude-sonnet-4-6",
          "amazon_bedrock:amazon.nova-pro-v1:0"
        ] do
      assert {:error, :unsupported_model_option} =
               ReqLLMAdapter.prepare_model(
                 selector,
                 Requirements.interim(%{max_tokens: 64}, :json_object)
               )

      assert {:ok, target, _status, _attestation} =
               ReqLLMAdapter.prepare_model(
                 selector,
                 Requirements.interim(%{max_tokens: 64}, :unsupported)
               )

      {:ok, invocation} =
        Invocation.new(
          %{messages: [%{role: :user, content: "hi"}], schema: schema},
          false,
          "test",
          nil
        )

      forced = %{
        put_test_http_options(target, plug)
        | structured_output_mode: :json_object
      }

      assert {:error, _reason} = ReqLLMAdapter.call(forced, invocation)
    end
  end

  test "bounds an omitted output budget below a model's full context window", %{test: test} do
    expect_request(test, "x-ai/grok-4.3")

    assert {:ok, %{content: "ok"}} =
             ReqLLMAdapter.generate_with_tools(
               "openrouter:x-ai/grok-4.3",
               [%{role: :user, content: "hi"}],
               [
                 %{
                   "type" => "function",
                   "function" => %{
                     "name" => "run_ptc_lisp",
                     "description" => "Run a program",
                     "parameters" => %{
                       "type" => "object",
                       "properties" => %{"program" => %{"type" => "string"}}
                     }
                   }
                 }
               ],
               api_key: "test",
               req_http_options: [plug: {Req.Test, test}]
             )

    assert_receive {:request_body, %{"max_tokens" => 4_096}}
  end

  test "carries normalized truncation and the configured effective request cap", %{test: test} do
    expect_request(test, "x-ai/grok-4.3", finish_reason: "length", content: "")

    assert {:ok,
            %{
              content: "",
              finish_reason: :length,
              output_limit: %{
                name: :max_tokens,
                value: 4_096,
                bindings: [:configured]
              }
            }} =
             ReqLLMAdapter.generate_with_tools(
               "openrouter:x-ai/grok-4.3",
               [%{role: :user, content: "hi"}],
               [tool_schema()],
               api_key: "test",
               max_tokens: 4_096,
               req_http_options: [plug: {Req.Test, test}]
             )

    assert_receive {:request_body, %{"max_tokens" => 4_096}}
  end

  test "records every binding tied for the computed effective request cap" do
    model =
      LLMDB.Model.new!(%{
        id: "binding-test",
        provider: :openrouter,
        limits: %{output: 4_096, context: 100_000}
      })

    assert {4_096, [:adapter_default, :model_output_limit]} =
             ReqLLMAdapter.effective_output_limit([], model, [%{role: :user, content: "hi"}])
  end

  test "treats a namespaced provider output budget as configured truncation provenance", %{
    test: test
  } do
    expect_request(test, "Qwen/Qwen3-30B-A3B-Instruct-2507",
      finish_reason: "length",
      content: ""
    )

    assert {:ok,
            %{
              finish_reason: :length,
              output_limit: %{value: 8_192, bindings: [:configured]}
            }} =
             ReqLLMAdapter.generate_with_tools(
               "nearai:Qwen/Qwen3-30B-A3B-Instruct-2507",
               [%{role: :user, content: "hi"}],
               [tool_schema()],
               api_key: "test",
               provider_options: [nearai: [max_completion_tokens: 8_192]],
               req_http_options: [plug: {Req.Test, test}]
             )

    assert_receive {:request_body, %{"max_tokens" => 8_192}}
  end

  test "does not invent provenance when a provider rewrites the request cap", %{test: test} do
    model =
      LLMDB.Model.new!(%{
        id: "accounts/fireworks/models/test-model",
        provider: :fireworks_ai,
        limits: %{output: 32_768, context: 128_000}
      })

    prepared = %ReqLLMPreparedModel{
      selector: "fireworks_ai:accounts/fireworks/models/test-model",
      model: model,
      exact_options: %{max_tokens: 8_192}
    }

    expect_request(test, model.id, finish_reason: "length", content: "")

    assert {:ok, %{finish_reason: :length} = response} =
             ReqLLMAdapter.generate_with_tools(
               prepared,
               [%{role: :user, content: "hi"}],
               [tool_schema()],
               api_key: "test",
               max_tokens: 8_192,
               req_http_options: [plug: {Req.Test, test}]
             )

    refute Map.has_key?(response, :output_limit)
    assert_receive {:request_body, %{"max_tokens" => 4_096}}
  end

  test "does not invent provenance for conflicting configured limits", %{test: test} do
    expect_request(test, "Qwen/Qwen3-30B-A3B-Instruct-2507",
      finish_reason: "length",
      content: ""
    )

    assert {:ok, %{finish_reason: :length} = response} =
             ReqLLMAdapter.generate_with_tools(
               "nearai:Qwen/Qwen3-30B-A3B-Instruct-2507",
               [%{role: :user, content: "hi"}],
               [tool_schema()],
               api_key: "test",
               max_tokens: 8_192,
               provider_options: [nearai: [max_completion_tokens: 4_096]],
               req_http_options: [plug: {Req.Test, test}]
             )

    refute Map.has_key?(response, :output_limit)
    assert_receive {:request_body, %{"max_tokens" => 8_192}}
  end

  test "does not claim a wire cap for the OpenAI Codex transport" do
    model =
      LLMDB.Model.new!(%{
        id: "future-chat-1408",
        provider: :openai_codex,
        limits: %{output: 32_768, context: 128_000}
      })

    assert :unknown =
             ReqLLMAdapter.effective_output_limit(
               [max_tokens: 4_096],
               model,
               [%{role: :user, content: "hi"}]
             )
  end

  test "does not raise the default above a smaller cataloged output limit", %{test: test} do
    expect_request(test, "google/gemma-2-27b-it")

    assert {:ok, %{content: "ok"}} =
             ReqLLMAdapter.generate_text(
               "openrouter:google/gemma-2-27b-it",
               [%{role: :user, content: "hi"}],
               api_key: "test",
               req_http_options: [plug: {Req.Test, test}]
             )

    assert_receive {:request_body, %{"max_tokens" => 2_048}}
  end

  test "a real Finch request uses current Req options without dependency warnings" do
    server =
      MCPHTTPFixture.start(fn _request ->
        body =
          Jason.encode!(%{
            "id" => "gen-test",
            "model" => "google/gemma-2-27b-it",
            "choices" => [
              %{
                "index" => 0,
                "finish_reason" => "stop",
                "message" => %{"role" => "assistant", "content" => "ok"}
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          })

        {200, [{"content-type", "application/json"}], body}
      end)

    on_exit(server.close)
    previous_openrouter = Application.fetch_env(:req_llm, :openrouter)
    Application.put_env(:req_llm, :openrouter, base_url: server.endpoint)

    on_exit(fn ->
      case previous_openrouter do
        {:ok, value} -> Application.put_env(:req_llm, :openrouter, value)
        :error -> Application.delete_env(:req_llm, :openrouter)
      end
    end)

    warnings =
      capture_io(:stderr, fn ->
        assert {:ok, %{content: "ok"}} =
                 ReqLLMAdapter.generate_text(
                   "openrouter:google/gemma-2-27b-it",
                   [%{role: :user, content: "hi"}],
                   api_key: "test",
                   receive_timeout: 2_000
                 )
      end)

    refute warnings =~ "deprecated"
  end

  test "preserves a namespaced provider output budget", %{test: test} do
    expect_request(test, "Qwen/Qwen3-30B-A3B-Instruct-2507")

    assert {:ok, %{content: "ok"}} =
             ReqLLMAdapter.generate_text(
               "nearai:Qwen/Qwen3-30B-A3B-Instruct-2507",
               [%{role: :user, content: "hi"}],
               api_key: "test",
               provider_options: [nearai: [max_completion_tokens: 8_192]],
               req_http_options: [plug: {Req.Test, test}]
             )

    assert_receive {:request_body, %{"max_tokens" => 8_192}}
  end

  test "reserves input space when the cataloged output meets the context limit", %{test: test} do
    expect_request(test, "openai/gpt-3.5-turbo-0613")

    assert {:ok, %{content: "ok"}} =
             ReqLLMAdapter.generate_text(
               "openrouter:openai/gpt-3.5-turbo-0613",
               [%{role: :user, content: "hi"}],
               api_key: "test",
               req_http_options: [plug: {Req.Test, test}]
             )

    assert_receive {:request_body, %{"max_tokens" => max_tokens}}
    assert max_tokens in 1..4_094
  end

  test "one requester prepares an uncataloged model once and owns its warning" do
    warnings =
      capture_io(:stderr, fn ->
        assert {:ok, prepared} = prepare_model("openrouter:vendor/new-model")
        assert {:ok, requester} = PtcRunner.LLM.callback(prepared, LLMSupport.llm_binding())
        assert is_function(requester, 2)
      end)

    assert length(Regex.scan(~r/model_uncataloged/, warnings)) == 1
    refute warnings =~ "Using unverified model"
    refute warnings =~ "ReqLLM.model"
    refute warnings =~ "req_llm.ex"
  end

  test "a cataloged model does not emit a catalog warning" do
    warnings =
      capture_io(:stderr, fn ->
        assert {:ok, prepared} = prepare_model("openrouter:google/gemma-2-27b-it")
        assert {:ok, _requester} = PtcRunner.LLM.callback(prepared, LLMSupport.llm_binding())
      end)

    refute warnings =~ "model_uncataloged"
  end

  test "direct HTTP routes report that catalog status is unavailable" do
    for selector <- ["ollama:local-model", "openai-compat:https://example.com/v1|deployment"] do
      assert {:ok,
              %{
                catalog_status: :unavailable,
                selector: ^selector,
                target: %{selector: ^selector}
              }} = prepare_model(selector)
    end
  end

  test "special uncataloged fallbacks preserve ReqLLM's public resolver fields" do
    selectors = [
      "github_copilot:future-chat-1408",
      "mistral:future-chat-1408",
      "minimax:future-chat-1408"
    ]

    for selector <- selectors do
      assert {:ok, expected} = ReqLLM.model(selector)

      assert {:ok,
              %{
                catalog_status: :uncataloged,
                target: %{model: actual, selector: ^selector}
              }} = prepare_model(selector)

      fields = [:provider, :id, :model, :provider_model_id, :capabilities, :limits, :extra]
      assert Map.take(actual, fields) == Map.take(expected, fields)
    end
  end

  test "openai_codex is refused because it drops the sealed max_tokens field" do
    assert {:error, :unsupported_model_option} =
             prepare_model("openai_codex:future-chat-1408")
  end

  test "Bedrock preparation preserves and supplies inference-profile prefixes" do
    set_bedrock_region("eu-west-1")

    prefixed = "amazon_bedrock:eu.amazon.nova-pro-v1:0"

    assert {:ok, %{catalog_status: :cataloged, target: %{model: prefixed_model}}} =
             prepare_model(prefixed)

    assert prefixed_model.provider_model_id == "eu.amazon.nova-pro-v1:0"

    unprefixed = "amazon_bedrock:amazon.nova-pro-v1:0"

    assert {:ok, %{catalog_status: :cataloged, target: %{model: unprefixed_model}}} =
             prepare_model(unprefixed)

    assert unprefixed_model.provider_model_id == "eu.amazon.nova-pro-v1:0"
  end

  test "an uncataloged Bedrock model emits only the PtcRunner warning" do
    set_bedrock_region("eu-west-1")
    selector = "amazon_bedrock:amazon.future-1408-v1:0"

    warning =
      capture_io(:stderr, fn ->
        assert {:ok, prepared} = prepare_model(selector)
        assert {:ok, _requester} = PtcRunner.LLM.callback(prepared, LLMSupport.llm_binding())
      end)

    assert length(Regex.scan(~r/model_uncataloged/, warning)) == 1
    refute warning =~ "Using unverified model"
    refute warning =~ "ReqLLM.model"

    assert {:ok, %{target: %{model: model}}} = prepare_model(selector)
    assert model.provider_model_id == "eu.amazon.future-1408-v1:0"
  end

  test "an invalid provider fails preparation without dependency warning frames" do
    warnings =
      capture_io(:stderr, fn ->
        assert {:error, :invalid_model} = prepare_model("provider1408:future-model")
      end)

    refute warnings =~ "ReqLLM"
    refute warnings =~ "req_llm.ex"
  end

  defp expect_request(test, response_model, opts \\ []) do
    Req.Test.expect(test, request_handler(self(), response_model, opts))
  end

  defp expect_object_request(test, response_model, content) do
    Req.Test.expect(test, request_handler(self(), response_model, content: content))
  end

  defp put_test_http_options(%ReqLLMPreparedModel{} = target, plug_or_test) do
    http_options =
      case plug_or_test do
        test when is_atom(test) -> [plug: {Req.Test, test}, retry: false]
        plug when is_function(plug, 1) -> [plug: plug, retry: false]
      end

    %{
      target
      | exact_options: Map.put(target.exact_options, :req_http_options, http_options),
        request_options:
          Map.put(target.request_options || target.exact_options, :req_http_options, http_options)
    }
  end

  defp prepare_model(selector) do
    PtcRunner.LLM.prepare(selector, LLMSupport.interim_requirements(), ReqLLMAdapter)
  end

  defp request_handler(test_pid, response_model, opts) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(body)})

      response = %{
        "id" => "gen-test",
        "model" => response_model,
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => Keyword.get(opts, :finish_reason, "stop"),
            "message" => %{
              "role" => "assistant",
              "content" => Keyword.get(opts, :content, "ok")
            }
          }
        ]
      }

      usage =
        Keyword.get(
          opts,
          :usage,
          %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
        )

      response = if is_nil(usage), do: response, else: Map.put(response, "usage", usage)
      Req.Test.json(conn, response)
    end
  end

  defp responses_request_handler(test_pid, response_model) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "resp-test",
        "model" => response_model,
        "status" => "completed",
        "output_text" => "ok",
        "output" => [],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      })
    end
  end

  defp tool_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => "run_ptc_lisp",
        "description" => "Run a program",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"program" => %{"type" => "string"}}
        }
      }
    }
  end

  defp set_bedrock_region(region) do
    previous_system_region = System.get_env("AWS_REGION")
    previous_configured_region = Application.fetch_env(:ptc_runner, :bedrock_region)

    on_exit(fn ->
      if previous_system_region,
        do: System.put_env("AWS_REGION", previous_system_region),
        else: System.delete_env("AWS_REGION")

      case previous_configured_region do
        {:ok, configured_region} ->
          Application.put_env(:ptc_runner, :bedrock_region, configured_region)

        :error ->
          Application.delete_env(:ptc_runner, :bedrock_region)
      end
    end)

    System.delete_env("AWS_REGION")
    Application.put_env(:ptc_runner, :bedrock_region, region)
  end
end
