defmodule PtcRunner.Kernel.HTTPDecisionsTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Kernel.HTTPDecisions
  alias PtcRunner.Kernel.OpenRouterDecisions
  alias PtcRunner.TestSupport.HTTPRequest

  @request %{
    "state" => %{"number" => 2},
    "questions" => %{"q" => %{"type" => "boolean", "instructions" => "Is it positive?"}}
  }

  test "neutral wire body, optional bearer and deadline clamp" do
    for credential <- [nil, "key"] do
      http = fn endpoint, opts ->
        assert endpoint == "https://example.test/decisions"
        assert opts[:json] == Map.put(@request, "model", "declared")
        assert opts[:auth] == if(credential, do: {:bearer, credential}, else: nil)
        assert opts[:retry] == false
        assert opts[:redirect] == false
        assert opts[:receive_timeout] in 1..500

        {:ok,
         %{
           status: 200,
           body: %{"model" => "served", "usage" => %{}, "answers" => %{}, "private" => true}
         }}
      end

      requester =
        HTTPDecisions.requester(
          "https://example.test/decisions",
          "declared",
          credential,
          45_000,
          http
        )

      assert {:ok, %{"model" => "served", "usage" => %{}, "answers" => %{}}} =
               requester.(@request, %{
                 llm_request_deadline_ms: System.monotonic_time(:millisecond) + 500
               })
    end
  end

  test "status and transport failures preserve dispatch evidence" do
    for {status, kind, retryable} <- [
          {401, :authentication_failed, false},
          {402, :payment_required, false},
          {429, :rate_limited, true},
          {400, :invalid_request, false},
          {503, :unavailable, true}
        ] do
      requester =
        HTTPDecisions.requester("https://example.test", "m", nil, 1000, fn _, _ ->
          {:ok, %{status: status}}
        end)

      assert {:error, error} = requester.(@request, %{})
      assert error.kind == kind
      assert error.retryable? == retryable
      assert error.dispatch_provenance == :dispatched
    end

    requester =
      HTTPDecisions.requester("https://example.test", "m", nil, 1000, fn _, _ ->
        {:error, :closed}
      end)

    assert {:error, %{kind: :transport_error, dispatch_provenance: :possibly_dispatched}} =
             requester.(@request, %{})
  end

  test "redirects never contact a second server for either backend" do
    for status <- [301, 302, 307, 308], backend <- [:http, :openrouter] do
      {:ok, target} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {_, target_port}} = :inet.sockname(target)
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {_, port}} = :inet.sockname(listener)

      task =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2000)
          {:ok, wire} = HTTPRequest.receive_complete(socket)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 #{status} Redirect\r\nLocation: http://127.0.0.1:#{target_port}/target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )

          :gen_tcp.close(socket)
          wire
        end)

      endpoint = "http://127.0.0.1:#{port}/decisions"

      requester =
        case backend do
          :http ->
            HTTPDecisions.requester(endpoint, "m", nil, 2000)

          :openrouter ->
            OpenRouterDecisions.requester("m", "key", %{}, 2000, fn fixed, opts ->
              assert fixed == "https://openrouter.ai/api/alpha/decisions"
              Req.post(endpoint, opts)
            end)
        end

      assert {:error, %{kind: :invalid_request, retryable?: false}} = requester.(@request, %{})
      assert Task.await(task) =~ "POST /decisions"
      assert {:error, :timeout} = :gen_tcp.accept(target, 20)
      :gen_tcp.close(listener)
      :gen_tcp.close(target)
    end
  end
end
