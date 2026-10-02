defmodule PtcViewer.HostSecurityTest do
  use ExUnit.Case, async: true
  import Plug.Test

  test "all local authorities require the listener port and HTTP" do
    opts = PtcViewer.Router.init(expected_port: 4123)

    for host <- ["localhost", "127.0.0.1", "[::1]"] do
      assert conn(:get, "http://#{host}:4123/missing")
             |> PtcViewer.Router.call(opts)
             |> Map.fetch!(:status) == 404

      for url <- [
            "http://#{host}:4124/missing",
            "http://#{host}/missing",
            "https://#{host}:4123/missing"
          ] do
        assert conn(:get, url) |> PtcViewer.Router.call(opts) |> Map.fetch!(:status) == 403
      end
    end
  end

  test "Live mutations use the shared strict same-origin policy" do
    opts = PtcViewer.Router.init(expected_port: 4123, live_mutation_nonce: "nonce")

    for origin <- [
          "https://localhost:4123",
          "http://localhost:4124",
          "http://127.0.0.1:4123",
          "http://user@localhost:4123",
          "http://localhost:4123/path"
        ] do
      response =
        conn(:delete, "http://localhost:4123/api/live/runs/run-1")
        |> Plug.Conn.put_req_header("origin", origin)
        |> Plug.Conn.put_req_header("x-ptc-viewer-live-nonce", "nonce")
        |> PtcViewer.Router.call(opts)

      assert response.status == 403
    end

    response =
      conn(:delete, "http://localhost:4123/api/live/runs/run-1")
      |> Plug.Conn.put_req_header("origin", "http://localhost:4123")
      |> Plug.Conn.put_req_header("x-ptc-viewer-live-nonce", "nonce")
      |> PtcViewer.Router.call(opts)

    assert response.status == 503
  end

  test "a wildcard listener rejects foreign Host headers before adapters or static assets" do
    {:ok, viewer} =
      PtcViewer.start(
        ip: {0, 0, 0, 0},
        port: 0,
        open: false,
        kernel_trace_adapter: fn _, _, _ -> flunk("foreign host reached the kernel adapter") end,
        live_trace_refresh: fn _ -> flunk("foreign host reached refresh") end
      )

    on_exit(fn -> PtcViewer.stop(viewer) end)
    {:ok, {_, port}} = PtcViewer.listener_info(viewer)

    for {method, path} <- [
          {"GET", "/api/kernel/runs"},
          {"GET", "/api/analysis/runs/run-1/result"},
          {"POST", "/api/kernel/refresh"},
          {"GET", "/js/app.js"}
        ] do
      assert request(port, method, path, "evil.example:#{port}") =~ "HTTP/1.1 403"
      assert request(port, method, path, "localhost:#{port + 1}") =~ "HTTP/1.1 403"
    end

    assert request(
             port,
             "GET",
             "http://localhost:#{port}/api/kernel/runs",
             "evil.example:#{port}"
           ) =~ "HTTP/1.1 403"

    assert request(port, "GET", "/js/app.js", "[::1]:#{port}") =~ "HTTP/1.1 200"
    assert request(port, "GET", "/js/app.js", "localhost:#{port}") =~ "HTTP/1.1 200"
  end

  defp request(port, method, path, host) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

    try do
      :ok =
        :gen_tcp.send(
          socket,
          "#{method} #{path} HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        )

      {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
      response
    after
      :gen_tcp.close(socket)
    end
  end
end
