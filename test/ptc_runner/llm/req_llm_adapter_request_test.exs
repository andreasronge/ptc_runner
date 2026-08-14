defmodule PtcRunner.LLM.ReqLLMAdapterRequestTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PtcRunner.LLM.ReqLLMAdapter
  alias PtcRunner.TestSupport.LLMSupport

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

  test "resolves an uncataloged model only once per request", %{test: test} do
    expect_request(test, "vendor/new-model")

    warnings =
      capture_io(:stderr, fn ->
        assert {:ok, %{content: "ok"}} =
                 ReqLLMAdapter.generate_text(
                   "openrouter:vendor/new-model",
                   [%{role: :user, content: "hi"}],
                   api_key: "test",
                   req_http_options: [plug: {Req.Test, test}]
                 )
      end)

    assert length(Regex.scan(~r/Using unverified model:/, warnings)) == 1
  end

  defp expect_request(test, response_model) do
    test_pid = self()

    Req.Test.expect(test, fn conn ->
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
    end)
  end
end
