defmodule PtcRunner.LLM.ReqLLMAdapterRequestTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PtcRunner.LLM.ReqLLMAdapter
  alias PtcRunner.TestSupport.LLMSupport
  alias PtcRunner.TestSupport.MCPHTTPFixture

  setup do
    LLMSupport.admit_provider_application!()
    :ok
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

  test "one requester prepares an uncataloged model once and owns its warning", %{test: test} do
    stub_requests(test, "vendor/new-model")

    warnings =
      capture_io(:stderr, fn ->
        {:ok, requester} =
          PtcRunner.LLM.callback("openrouter:vendor/new-model",
            adapter: ReqLLMAdapter,
            api_key: "test",
            req_http_options: [plug: {Req.Test, test}]
          )

        for content <- ["first", "second"] do
          assert {:ok, %{content: "ok"}} =
                   requester.(%{messages: [%{role: :user, content: content}]})
        end
      end)

    assert length(Regex.scan(~r/model_uncataloged/, warnings)) == 1
    refute warnings =~ "Using unverified model"
    refute warnings =~ "ReqLLM.model"
    refute warnings =~ "req_llm.ex"

    assert_receive {:request_body, %{"model" => "vendor/new-model"}}
    assert_receive {:request_body, %{"model" => "vendor/new-model"}}
  end

  test "a cataloged model does not emit a catalog warning" do
    warnings =
      capture_io(:stderr, fn ->
        assert {:ok, _requester} =
                 PtcRunner.LLM.callback("openrouter:google/gemma-2-27b-it",
                   adapter: ReqLLMAdapter
                 )
      end)

    refute warnings =~ "model_uncataloged"
  end

  test "direct HTTP routes report that catalog status is unavailable" do
    for selector <- ["ollama:local-model", "openai-compat:https://example.com/v1|deployment"] do
      assert {:ok, %{catalog_status: :unavailable, selector: ^selector, target: ^selector}} =
               PtcRunner.LLM.prepare(selector, ReqLLMAdapter)
    end
  end

  test "special uncataloged fallbacks preserve ReqLLM's public resolver fields" do
    selectors = [
      "openai_codex:future-chat-1408",
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
              }} = PtcRunner.LLM.prepare(selector, ReqLLMAdapter)

      fields = [:provider, :id, :model, :provider_model_id, :capabilities, :limits, :extra]
      assert Map.take(actual, fields) == Map.take(expected, fields)
    end
  end

  test "Bedrock preparation preserves and supplies inference-profile prefixes" do
    set_bedrock_region("eu-west-1")

    prefixed = "amazon_bedrock:eu.amazon.nova-pro-v1:0"

    assert {:ok, %{catalog_status: :cataloged, target: %{model: prefixed_model}}} =
             PtcRunner.LLM.prepare(prefixed, ReqLLMAdapter)

    assert prefixed_model.provider_model_id == "eu.amazon.nova-pro-v1:0"

    unprefixed = "amazon_bedrock:amazon.nova-pro-v1:0"

    assert {:ok, %{catalog_status: :cataloged, target: %{model: unprefixed_model}}} =
             PtcRunner.LLM.prepare(unprefixed, ReqLLMAdapter)

    assert unprefixed_model.provider_model_id == "eu.amazon.nova-pro-v1:0"
  end

  test "an uncataloged Bedrock model emits only the PtcRunner warning" do
    set_bedrock_region("eu-west-1")
    selector = "amazon_bedrock:amazon.future-1408-v1:0"

    warning =
      capture_io(:stderr, fn ->
        assert {:ok, _requester} = PtcRunner.LLM.callback(selector, adapter: ReqLLMAdapter)
      end)

    assert length(Regex.scan(~r/model_uncataloged/, warning)) == 1
    refute warning =~ "Using unverified model"
    refute warning =~ "ReqLLM.model"

    assert {:ok, %{target: %{model: model}}} = PtcRunner.LLM.prepare(selector, ReqLLMAdapter)
    assert model.provider_model_id == "eu.amazon.future-1408-v1:0"
  end

  test "an invalid provider fails preparation without dependency warning frames" do
    warnings =
      capture_io(:stderr, fn ->
        assert {:error, :invalid_model} =
                 PtcRunner.LLM.callback("provider1408:future-model", adapter: ReqLLMAdapter)
      end)

    refute warnings =~ "ReqLLM"
    refute warnings =~ "req_llm.ex"
  end

  defp expect_request(test, response_model) do
    Req.Test.expect(test, request_handler(self(), response_model))
  end

  defp stub_requests(test, response_model) do
    Req.Test.stub(test, request_handler(self(), response_model))
  end

  defp request_handler(test_pid, response_model) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "gen-test",
        "model" => response_model,
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "ok"}
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      })
    end
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
