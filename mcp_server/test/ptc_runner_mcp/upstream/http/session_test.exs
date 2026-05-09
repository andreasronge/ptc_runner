defmodule PtcRunnerMcp.Upstream.Http.SessionTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Upstream.Http.Session

  doctest Session

  describe "new/0" do
    test "starts with handshake incomplete and id 1" do
      s = Session.new()
      assert s.handshake_complete? == false
      assert s.session_id == nil
      assert s.negotiated_version == nil
      assert s.next_id == 1
    end
  end

  describe "next_request_id/1" do
    test "is monotonic and threads through state" do
      {id1, s} = Session.next_request_id(Session.new())
      {id2, s} = Session.next_request_id(s)
      {id3, s} = Session.next_request_id(s)
      assert [id1, id2, id3] == [1, 2, 3]
      assert s.next_id == 4
    end
  end

  describe "apply_initialize_response/2" do
    @ok_body %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "serverInfo" => %{"name" => "test-srv", "version" => "0.1.0"}
      }
    }

    test "accepts the negotiated 2025-06-18 version and captures session id" do
      response = %{
        status: 200,
        headers: [
          {"content-type", "application/json"},
          {"Mcp-Session-Id", "abc-123"},
          {"MCP-Protocol-Version", "2025-06-18"}
        ],
        body: @ok_body
      }

      {:ok, s} = Session.apply_initialize_response(Session.new(), response)
      assert s.session_id == "abc-123"
      assert s.negotiated_version == "2025-06-18"
      # Handshake is NOT yet complete — caller still has to POST
      # notifications/initialized.
      refute s.handshake_complete?
    end

    test "session-id header lookup is case-insensitive" do
      response = %{
        status: 200,
        headers: [
          {"content-type", "application/json"},
          # Server speaks all-lowercase per HTTP/2 conventions.
          {"mcp-session-id", "lowercase-id"}
        ],
        body: @ok_body
      }

      {:ok, s} = Session.apply_initialize_response(Session.new(), response)
      assert s.session_id == "lowercase-id"
    end

    test "absent session id is OK (stateless server)" do
      response = %{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: @ok_body
      }

      {:ok, s} = Session.apply_initialize_response(Session.new(), response)
      assert s.session_id == nil
      # Echoed protocol-version header may still be absent — fall back
      # to the body's protocolVersion.
      assert s.negotiated_version == "2025-06-18"
    end

    test "rejects a server-supplied protocolVersion that doesn't match 2025-06-18" do
      body = put_in(@ok_body, ["result", "protocolVersion"], "2025-03-26")
      response = %{status: 200, headers: [], body: body}

      assert {:error, :upstream_unavailable, detail} =
               Session.apply_initialize_response(Session.new(), response)

      assert detail =~ "protocol version mismatch"
    end

    test "rejects body missing result.protocolVersion" do
      response = %{status: 200, headers: [], body: %{"result" => %{}}}

      assert {:error, :upstream_error, detail} =
               Session.apply_initialize_response(Session.new(), response)

      assert detail =~ "missing result.protocolVersion"
    end

    test "rejects non-200 initialize status" do
      response = %{status: 500, headers: [], body: @ok_body}

      assert {:error, :upstream_unavailable, detail} =
               Session.apply_initialize_response(Session.new(), response)

      assert detail =~ "http 500"
    end
  end

  describe "apply_handshake_complete/1" do
    test "flips handshake_complete? to true" do
      s = Session.new() |> Session.apply_handshake_complete()
      assert s.handshake_complete?
    end
  end

  describe "session_lost?/2" do
    test "true on 404 with held session id" do
      s = %Session{session_id: "abc"}
      assert Session.session_lost?(s, %{status: 404})
    end

    test "false on 404 with no session id (stateless server case)" do
      s = %Session{session_id: nil}
      refute Session.session_lost?(s, %{status: 404})
    end

    test "false on non-404 status even with a session id" do
      s = %Session{session_id: "abc"}
      refute Session.session_lost?(s, %{status: 200})
      refute Session.session_lost?(s, %{status: 500})
      refute Session.session_lost?(s, %{status: 401})
    end
  end

  describe "headers_for_initialize/2" do
    test "omits MCP-Protocol-Version and Mcp-Session-Id (§6.1.1)" do
      headers = Session.headers_for_initialize(Session.new(), [])

      keys = Enum.map(headers, fn {k, _} -> String.downcase(k) end)
      assert "content-type" in keys
      assert "accept" in keys
      refute "mcp-protocol-version" in keys
      refute "mcp-session-id" in keys
    end

    test "includes accept: application/json, text/event-stream" do
      headers = Session.headers_for_initialize(Session.new(), [])
      {_, accept} = Enum.find(headers, fn {k, _} -> String.downcase(k) == "accept" end)
      assert String.contains?(accept, "application/json")
      assert String.contains?(accept, "text/event-stream")
    end

    test "appends caller-supplied headers (e.g. Authorization)" do
      headers = Session.headers_for_initialize(Session.new(), [{"authorization", "Bearer x"}])
      assert {"authorization", "Bearer x"} in headers
    end
  end

  describe "headers_for_post/2" do
    test "always includes MCP-Protocol-Version after handshake" do
      s = Session.new() |> Session.apply_handshake_complete()
      headers = Session.headers_for_post(s, [])
      assert {"mcp-protocol-version", "2025-06-18"} in headers
    end

    test "includes Mcp-Session-Id when set" do
      s = %Session{session_id: "session-xyz"}
      headers = Session.headers_for_post(s, [])
      assert {"mcp-session-id", "session-xyz"} in headers
    end

    test "omits Mcp-Session-Id when nil (stateless server)" do
      headers = Session.headers_for_post(%Session{session_id: nil}, [])
      keys = Enum.map(headers, fn {k, _} -> String.downcase(k) end)
      refute "mcp-session-id" in keys
    end
  end

  # ─── codex P1 #2 belt-and-suspenders for `76f68de` ───
  #
  # `Application.@static_headers_denylist` is the primary defence; these
  # tests pin that even if a config-loader bypass smuggled a
  # protocol-controlled header through, `Session` would still strip it
  # at header-construction time.
  describe "filter_protocol_controlled (belt-and-suspenders)" do
    test "headers_for_initialize/2 strips MCP-Protocol-Version from extras" do
      extras = [{"mcp-protocol-version", "1999-01-01"}, {"x-custom", "ok"}]
      headers = Session.headers_for_initialize(Session.new(), extras)

      # Initialize MUST omit MCP-Protocol-Version per §6.1.1; the
      # extra value MUST NOT be smuggled in.
      refute Enum.any?(headers, fn {k, _} ->
               is_binary(k) and String.downcase(k) == "mcp-protocol-version"
             end)

      # Non-protocol-controlled extras pass through.
      assert {"x-custom", "ok"} in headers
    end

    test "headers_for_initialize/2 strips Mcp-Session-Id from extras" do
      extras = [{"Mcp-Session-Id", "fake"}]
      headers = Session.headers_for_initialize(Session.new(), extras)

      refute Enum.any?(headers, fn {k, _} ->
               is_binary(k) and String.downcase(k) == "mcp-session-id"
             end)
    end

    test "headers_for_initialize/2 strips User-Agent (case-insensitive) from extras" do
      extras = [{"USER-AGENT", "evil/1.0"}, {"X-Other", "kept"}]
      headers = Session.headers_for_initialize(Session.new(), extras)

      refute Enum.any?(headers, fn {k, _} ->
               is_binary(k) and String.downcase(k) == "user-agent"
             end)

      assert {"X-Other", "kept"} in headers
    end

    test "headers_for_post/2 strips a smuggled MCP-Protocol-Version override" do
      s = Session.new() |> Session.apply_handshake_complete()
      headers = Session.headers_for_post(s, [{"MCP-Protocol-Version", "1999-01-01"}])

      mcp_pv =
        Enum.filter(headers, fn {k, _} ->
          is_binary(k) and String.downcase(k) == "mcp-protocol-version"
        end)

      # Exactly one MCP-Protocol-Version, and it's the impl-controlled
      # one (the extra was dropped, not appended).
      assert [{"mcp-protocol-version", "2025-06-18"}] = mcp_pv
    end

    test "headers_for_post/2 strips a smuggled Mcp-Session-Id override" do
      s = %Session{session_id: "real-session"}
      headers = Session.headers_for_post(s, [{"mcp-session-id", "fake-session"}])

      session_ids =
        Enum.filter(headers, fn {k, _} ->
          is_binary(k) and String.downcase(k) == "mcp-session-id"
        end)

      assert [{"mcp-session-id", "real-session"}] = session_ids
    end

    test "headers_for_post/2 strips Content-Type / Accept overrides too" do
      s = Session.new() |> Session.apply_handshake_complete()

      headers =
        Session.headers_for_post(s, [
          {"Content-Type", "text/plain"},
          {"accept", "*/*"}
        ])

      ct =
        Enum.filter(headers, fn {k, _} ->
          is_binary(k) and String.downcase(k) == "content-type"
        end)

      accept =
        Enum.filter(headers, fn {k, _} ->
          is_binary(k) and String.downcase(k) == "accept"
        end)

      assert [{"content-type", "application/json"}] = ct
      assert [{"accept", "application/json, text/event-stream"}] = accept
    end
  end

  describe "JSON-RPC body shapes" do
    test "initialize_body/2 includes the version, capabilities, and clientInfo" do
      body = Session.initialize_body(Session.new(), %{"name" => "client", "version" => "1.0"})

      assert body["jsonrpc"] == "2.0"
      assert body["method"] == "initialize"
      assert body["id"] == 1
      assert body["params"]["protocolVersion"] == "2025-06-18"
      assert body["params"]["capabilities"] == %{}
      assert body["params"]["clientInfo"] == %{"name" => "client", "version" => "1.0"}
    end

    test "notifications_initialized_body/0 has no id (notification)" do
      body = Session.notifications_initialized_body()
      assert body["jsonrpc"] == "2.0"
      assert body["method"] == "notifications/initialized"
      refute Map.has_key?(body, "id")
    end

    test "tools_list_body/1 returns body and bumps the session id" do
      {body, s} = Session.tools_list_body(Session.new())
      assert body["jsonrpc"] == "2.0"
      assert body["method"] == "tools/list"
      assert body["id"] == 1
      assert s.next_id == 2
    end
  end
end
