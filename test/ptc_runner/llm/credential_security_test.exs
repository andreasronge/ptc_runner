defmodule PtcRunner.LLM.CredentialSecurityTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.LiveStatus.Reporter
  alias PtcRunner.LLM.Invocation
  alias PtcRunner.LLM.ReqLLMAdapter
  alias PtcRunner.LLM.Requirements
  alias PtcRunner.TestSupport.MCPHTTPFixture

  test "invocations do not expose credentials through inspection" do
    {:ok, invocation} = Invocation.new(%{}, false, "private-api-key", nil)
    refute inspect(invocation) =~ "private-api-key"
  end

  test "remote plaintext endpoints refuse provider and Viewer credentials" do
    assert {:error, _} =
             ReqLLMAdapter.generate_text("openai-compat:http://example.com/v1|model", [],
               api_key: "private-api-key",
               req_http_options: [plug: fn _ -> flunk("insecure request was dispatched") end]
             )

    assert :error = Reporter.report_http("http://example.com", "run", %{}, "private-token")
  end

  test "non-map successful provider responses return invalid_result" do
    server = MCPHTTPFixture.start(fn _ -> {200, [{"content-type", "text/html"}], "<html/>"} end)
    on_exit(server.close)

    assert {:ok, target, :unavailable, _attestation} =
             ReqLLMAdapter.prepare_model(
               "openai-compat:#{server.endpoint}|model",
               Requirements.interim(%{max_tokens: 64})
             )

    {:ok, invocation} =
      Invocation.new(%{messages: [%{role: :user, content: "hi"}]}, false, nil, nil)

    assert {:error, %ProviderError{kind: :invalid_result}} =
             ReqLLMAdapter.call(target, invocation)
  end

  test "malformed JSON success envelopes return invalid_result" do
    for body <- [[], nil, %{"choices" => "invalid"}, %{"choices" => [%{"message" => "invalid"}]}] do
      assert {:error, %ProviderError{kind: :invalid_result}} =
               ReqLLMAdapter.generate_text("openai-compat:https://example.com|model", [],
                 req_http_options: [plug: fn conn -> Req.Test.json(conn, body) end]
               )
    end
  end

  test "provider response bodies are capped and error bodies truncated" do
    server = MCPHTTPFixture.start(fn _ -> {200, [], String.duplicate("x", 4_194_305)} end)
    on_exit(server.close)

    assert {:error,
            %ProviderError{kind: :invalid_result, details: "LLM response exceeds 4194304 bytes"}} =
             ReqLLMAdapter.generate_text("openai-compat:#{server.endpoint}|model", [])

    error_server = MCPHTTPFixture.start(fn _ -> {500, [], String.duplicate("x", 10_000)} end)
    on_exit(error_server.close)

    assert {:error, %{body: body}} =
             ReqLLMAdapter.generate_text("openai-compat:#{error_server.endpoint}|model", [])

    assert body == String.duplicate("x", 4_096)
  end

  test "invalid endpoint schemes and hosts never dispatch" do
    for url <- [
          "ftp://example.com",
          "http:///v1",
          "http://",
          "https://user:pass@example.com",
          "https://example.com?secret=x",
          "https://example.com#fragment",
          "https://example.com:99999"
        ] do
      assert {:error, :invalid_endpoint} =
               ReqLLMAdapter.generate_text("openai-compat:#{url}|model", [],
                 req_http_options: [plug: fn _ -> flunk("invalid endpoint dispatched") end]
               )
    end
  end

  test "keyless remote HTTP and credentialed HTTPS or loopback keep their auth contract" do
    for {url, credential} <- [
          {"http://example.com", nil},
          {"https://example.com", "key"},
          {"http://localhost", "key"},
          {"http://127.5.6.7", "key"},
          {"http://[::1]", "key"}
        ] do
      plug = fn conn ->
        expected = if credential, do: ["Bearer " <> credential], else: []
        assert Plug.Conn.get_req_header(conn, "authorization") == expected
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
      end

      assert {:ok, %{content: "ok"}} =
               ReqLLMAdapter.generate_text("openai-compat:#{url}|model", [],
                 api_key: credential,
                 req_http_options: [plug: plug]
               )
    end
  end

  test "provider and Viewer redirects do not forward credentials" do
    destination = MCPHTTPFixture.start(fn _ -> flunk("redirect followed") end)
    on_exit(destination.close)

    server =
      MCPHTTPFixture.start(fn _ -> {307, [{"location", destination.endpoint}], "redirect"} end)

    on_exit(server.close)

    assert {:error, %{status: 307}} =
             ReqLLMAdapter.generate_text("openai-compat:#{server.endpoint}|model", [],
               api_key: "key"
             )

    assert :error = Reporter.report_http(server.endpoint, "run", %{}, "token")
  end

  test "loopback Viewer delivery carries its token" do
    parent = self()

    server =
      MCPHTTPFixture.start(fn request ->
        send(parent, {:viewer_request, request})
        {200, [], ""}
      end)

    on_exit(server.close)
    assert :ok = Reporter.report_http(server.endpoint, "run", %{}, "token")
    assert_receive {:viewer_request, request}
    assert request.headers["authorization"] == "Bearer token"
  end
end
