defmodule PtcRunner.Kernel.MCPHTTPAdapterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPHTTPAdapter

  test "does not consume unrelated messages from the caller mailbox" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\n{}")
        :gen_tcp.close(socket)
      end)

    send(self(), :unrelated)

    assert {:ok, %{status: 200, body: "{}"}} =
             MCPHTTPAdapter.request(
               method: :get,
               url: "http://127.0.0.1:#{port}/",
               timeout_ms: 1_000
             )

    assert_receive :unrelated
    _ = Task.shutdown(server, 1_000)
    :gen_tcp.close(listener)
  end

  test "closes the worker socket when its caller dies" do
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        send(parent, :request_received)
        result = :gen_tcp.recv(socket, 0, 1_000)
        :gen_tcp.close(socket)
        result
      end)

    caller =
      spawn(fn ->
        MCPHTTPAdapter.request(
          method: :get,
          url: "http://127.0.0.1:#{port}/",
          timeout_ms: 5_000
        )
      end)

    caller_ref = Process.monitor(caller)
    assert_receive :request_received, 1_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 1_000
    assert {:ok, {:error, :closed}} = Task.yield(server, 1_000)
    :gen_tcp.close(listener)
  end

  test "enforces the body ceiling across separately delivered chunks" do
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n3\r\nabc\r\n"
          )

        send(parent, {:first_wire_chunk, self()})

        receive do
          :send_second_chunk -> :ok
        end

        :ok = :gen_tcp.send(socket, "3\r\ndef\r\n0\r\n\r\n")
        :gen_tcp.close(socket)
      end)

    on_data = fn response, data ->
      send(parent, {:response_data, data})
      {:cont, %{response | body: response.body <> data}}
    end

    client =
      Task.async(fn ->
        MCPHTTPAdapter.request(
          method: :get,
          url: "http://127.0.0.1:#{port}/",
          timeout_ms: 1_000,
          max_body_bytes: 5,
          on_data: on_data
        )
      end)

    assert_receive {:first_wire_chunk, server_pid}, 1_000
    assert_receive {:response_data, "abc"}, 1_000
    send(server_pid, :send_second_chunk)

    assert {:ok, {:error, :response_exceeded, :possibly_dispatched}} =
             Task.yield(client, 1_000)

    _ = Task.shutdown(server, 1_000)
    :gen_tcp.close(listener)
  end

  test "an exception while consuming a dispatched response is possibly dispatched" do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 1\r\n\r\nx")
        :gen_tcp.close(socket)
      end)

    assert {:error, :transport_error, :possibly_dispatched} =
             MCPHTTPAdapter.request(
               method: :get,
               url: "http://127.0.0.1:#{port}/",
               timeout_ms: 1_000,
               on_data: fn _response, _data -> raise "consumer failed" end
             )

    _ = Task.shutdown(server, 1_000)
    :gen_tcp.close(listener)
  end

  test "retains final response headers when chunked trailers arrive" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\n" <>
              "content-type: application/json\r\n" <>
              "transfer-encoding: chunked\r\n" <>
              "trailer: x-checksum\r\n\r\n" <>
              "2\r\n{}\r\n0\r\nx-checksum: ok\r\n\r\n"
          )

        :gen_tcp.close(socket)
      end)

    assert {:ok, response} =
             MCPHTTPAdapter.request(
               method: :get,
               url: "http://127.0.0.1:#{port}/",
               timeout_ms: 1_000
             )

    assert MCPHTTPAdapter.get_header(response, "content-type") == ["application/json"]
    assert MCPHTTPAdapter.get_header(response, "x-checksum") == ["ok"]
    assert response.body == "{}"
    _ = Task.shutdown(server, 1_000)
    :gen_tcp.close(listener)
  end

  test "configures Mint to reject a response above the declared header-byte ceiling" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nx-oversized: " <> String.duplicate("a", 256) <> "\r\n\r\n"
          )

        :gen_tcp.close(socket)
      end)

    assert {:error, :response_exceeded, :possibly_dispatched} =
             MCPHTTPAdapter.request(
               method: :get,
               url: "http://127.0.0.1:#{port}/",
               timeout_ms: 1_000,
               max_header_bytes: 64
             )

    _ = Task.shutdown(server, 1_000)
    :gen_tcp.close(listener)
  end

  test "closes a connection rejected by the peer verifier before dispatch" do
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        send(parent, :accepted)
        result = :gen_tcp.recv(socket, 0, 1_000)
        :gen_tcp.close(socket)
        result
      end)

    assert {:error, :transport_error, :not_dispatched} =
             MCPHTTPAdapter.request(
               method: :get,
               url: "http://127.0.0.1:#{port}/",
               timeout_ms: 1_000,
               connected_peer: fn _address -> {:error, :peer_rejected} end
             )

    assert_receive :accepted, 1_000
    assert {:ok, {:error, :closed}} = Task.yield(server, 1_000)
    :gen_tcp.close(listener)
  end

  test "connects to an explicitly selected IPv6 address" do
    address = {0, 0, 0, 0, 0, 0, 0, 1}

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        :inet6,
        active: false,
        reuseaddr: true,
        ip: address
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\n{}")
        :gen_tcp.close(socket)
      end)

    assert {:ok, %{status: 200, body: "{}"}} =
             MCPHTTPAdapter.request(
               method: :get,
               url: "http://[::1]:#{port}/",
               address: address,
               timeout_ms: 1_000
             )

    _ = Task.shutdown(server, 1_000)
    :gen_tcp.close(listener)
  end
end
