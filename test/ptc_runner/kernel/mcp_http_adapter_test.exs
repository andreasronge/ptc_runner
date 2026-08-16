defmodule PtcRunner.Kernel.MCPHTTPAdapterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPHTTPAdapter
  alias PtcRunner.TestSupport.TLSFixture

  test "classifies only closed, admitted connect failures" do
    assert :connection_refused =
             MCPHTTPAdapter.classify_connect_error(
               :http,
               %Mint.TransportError{reason: :econnrefused}
             )

    assert :name_not_resolved =
             MCPHTTPAdapter.classify_connect_error(
               :https,
               %Mint.TransportError{reason: :nxdomain}
             )

    for alert <- [
          :unexpected_message,
          :unknown_ca,
          :protocol_version,
          :missing_extension,
          :certificate_required
        ] do
      assert :tls_handshake_failed =
               MCPHTTPAdapter.classify_connect_error(
                 :https,
                 %Mint.TransportError{reason: {:tls_alert, {alert, ~c"private detail"}}}
               )
    end

    for reason <- [
          :closed,
          {:tls_alert, {:internal_error, ~c"private detail"}},
          {:tls_alert, {:user_canceled, ~c"private detail"}},
          {:tls_alert, {:close_notify, ~c"private detail"}},
          {:tls_alert, {:future_alert, ~c"private detail"}},
          {:tls_alert, :invalid_shape},
          :enetunreach
        ] do
      assert :transport_error =
               MCPHTTPAdapter.classify_connect_error(
                 :https,
                 %Mint.TransportError{reason: reason}
               )
    end

    assert :transport_error =
             MCPHTTPAdapter.classify_connect_error(
               :http,
               %Mint.TransportError{
                 reason: {:tls_alert, {:unexpected_message, ~c"private detail"}}
               }
             )
  end

  test "collapses per-address connect failures without publishing a misleading cause" do
    assert :connection_refused =
             MCPHTTPAdapter.collapse_connect_failures([:connection_refused, :connection_refused])

    assert :transport_error =
             MCPHTTPAdapter.collapse_connect_failures([:connection_refused, :transport_error])

    assert :transport_error =
             MCPHTTPAdapter.collapse_connect_failures([
               :tls_handshake_failed,
               :connection_refused
             ])

    addresses = for last <- 1..17, do: {198, 51, 100, last}

    {accepted, deferred, overflow?} =
      MCPHTTPAdapter.partition_connect_candidates(MapSet.new(), addresses, 16)

    assert length(accepted) == 16
    assert deferred == []
    assert overflow?

    ipv6_addresses =
      for last <- 1..16, do: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, last}

    {accepted_ipv6, deferred_ipv6, overflow?} =
      MCPHTTPAdapter.partition_connect_candidates(MapSet.new(), ipv6_addresses, 8)

    assert length(accepted_ipv6) == 8
    assert length(deferred_ipv6) == 8
    refute overflow?

    assert {^deferred_ipv6, []} =
             MCPHTTPAdapter.release_deferred_candidates(
               MapSet.new(accepted_ipv6),
               deferred_ipv6
             )

    assert {[{198, 51, 100, 1}], [], false} =
             MCPHTTPAdapter.partition_connect_candidates(
               MapSet.new(accepted_ipv6),
               [{198, 51, 100, 1}],
               8
             )
  end

  test "waits for every losing connect worker to terminate" do
    workers =
      for _index <- 1..2 do
        spawn_link(fn ->
          receive do
            :never -> :ok
          end
        end)
      end

    assert :ok = MCPHTTPAdapter.terminate_workers(workers)
    refute Enum.any?(workers, &Process.alive?/1)
  end

  test "owner death during cleanup still terminates every linked worker" do
    parent = self()

    owner =
      spawn(fn ->
        workers =
          for _index <- 1..2 do
            spawn_link(fn ->
              receive do
                :never -> :ok
              end
            end)
          end

        send(parent, {:cleanup_workers, workers})

        MCPHTTPAdapter.terminate_workers(workers, fn killed ->
          send(parent, {:worker_kill_sent, self(), killed})

          receive do
            :continue_cleanup -> :ok
          end
        end)
      end)

    assert_receive {:cleanup_workers, workers}
    monitors = Enum.map(workers, &{&1, Process.monitor(&1)})
    assert_receive {:worker_kill_sent, ^owner, _first_worker}

    Process.exit(owner, :kill)

    Enum.each(monitors, fn {worker, monitor} ->
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    end)
  end

  test "races through a ninth same-family approved address" do
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

    refused = for last <- 2..9, do: {127, 0, 0, last}

    assert {:ok, %{status: 200, body: "{}"}} =
             MCPHTTPAdapter.request(
               method: :get,
               url: "http://localhost:#{port}/",
               address: refused ++ [{127, 0, 0, 1}],
               timeout_ms: 1_000
             )

    assert {:ok, :ok} = Task.yield(server, 1_000)
    :gen_tcp.close(listener)
  end

  test "returns distinct closed reasons for refused, unresolved, and TLS-mismatched connects" do
    {:ok, refused_listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, refused_port}} = :inet.sockname(refused_listener)
    :ok = :gen_tcp.close(refused_listener)

    assert {:error, :connection_refused, :not_dispatched} =
             MCPHTTPAdapter.request(
               method: :get,
               url: "http://127.0.0.1:#{refused_port}/",
               timeout_ms: 1_000
             )

    {:ok, ipv6_refused_listener} =
      :gen_tcp.listen(0, [
        :binary,
        :inet6,
        active: false,
        reuseaddr: true,
        ip: {0, 0, 0, 0, 0, 0, 0, 1}
      ])

    {:ok, {_address, ipv6_refused_port}} = :inet.sockname(ipv6_refused_listener)
    :ok = :gen_tcp.close(ipv6_refused_listener)

    assert {:error, :connection_refused, :not_dispatched} =
             MCPHTTPAdapter.request(
               method: :get,
               url: "http://[::1]:#{ipv6_refused_port}/",
               timeout_ms: 1_000
             )

    assert {:error, :name_not_resolved, :not_dispatched} =
             MCPHTTPAdapter.request(
               method: :get,
               url: "https://unresolved.invalid/",
               address: "",
               timeout_ms: 1_000
             )

    {:ok, plaintext_listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, plaintext_port}} = :inet.sockname(plaintext_listener)

    plaintext_server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(plaintext_listener, 5_000)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\n\r\n")
        :gen_tcp.close(socket)
      end)

    assert {:error, :tls_handshake_failed, :not_dispatched} =
             MCPHTTPAdapter.request(
               method: :get,
               url: "https://localhost:#{plaintext_port}/",
               address: {127, 0, 0, 1},
               timeout_ms: 5_000
             )

    assert {:ok, :ok} = Task.yield(plaintext_server, 5_000)
    :gen_tcp.close(plaintext_listener)
  end

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

  describe "receive ceiling" do
    @receive_cap 16_384
    @body_bytes 4 * 1024 * 1024

    test "bounds one socket message to the declared receive ceiling over TCP" do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, {_address, port}} = :inet.sockname(listener)

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)

          # Answered on accept rather than on request, so the peer's bytes are
          # in flight as early as it can make them. This does NOT reach the
          # window between arming and the ceiling — connecting in :active mode
          # leaves every test here green — it only makes the peer adversarial.
          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-length: #{@body_bytes}\r\n\r\n"
            )

          # One write, so the ceiling is the only thing that can split it.
          :ok = :gen_tcp.send(socket, :binary.copy(<<?x>>, @body_bytes))
          {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
          :gen_tcp.close(socket)
        end)

      assert {:ok, %{status: 200} = response} =
               MCPHTTPAdapter.request(
                 method: :get,
                 url: "http://127.0.0.1:#{port}/",
                 timeout_ms: 10_000,
                 max_body_bytes: 8 * 1024 * 1024,
                 max_receive_bytes: @receive_cap,
                 on_data: &record_chunk/2
               )

      # The peer wrote the body in one call, so an unbounded adapter delivers it
      # in one 4 MiB chunk and fails the ceiling. The chunk *count* is
      # deliberately not asserted: it is 256 exactly plus however many short
      # reads the driver happened to make, which is a scheduling accident.
      assert response.received == @body_bytes
      assert response.largest_chunk <= @receive_cap

      _ = Task.shutdown(server, 2_000)
      :gen_tcp.close(listener)
    end

    # `request/1` trusts only the OS certificate store, by design, so no
    # loopback TLS server can be reached through it. This drives the adapter's
    # own `:ssl` branch over a real TLS socket instead. It pins that branch and
    # nothing else: that `activate/2` calls it, and calls it with the connection's
    # own scheme, is covered by the TCP test above and by nothing here.
    test "applies the receive ceiling through :ssl for an https connection" do
      {listener, port} = TLSFixture.listen()

      server =
        Task.async(fn ->
          {:ok, socket} = TLSFixture.accept(listener, 5_000)
          {:ok, _request} = :ssl.recv(socket, 0, 5_000)

          :ok =
            :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: #{@body_bytes}\r\n\r\n")

          :ok = :ssl.send(socket, :binary.copy(<<?x>>, @body_bytes))
          :ssl.close(socket)
        end)

      {:ok, connection} =
        Mint.HTTP.connect(:https, "localhost", port,
          protocols: [:http1],
          mode: :passive,
          transport_opts: [verify: :verify_none, inet4: true, inet6: false]
        )

      assert :ok = MCPHTTPAdapter.apply_receive_cap(connection, :https, @receive_cap)
      {:ok, connection} = Mint.HTTP.set_mode(connection, :active)
      {:ok, connection, _ref} = Mint.HTTP.request(connection, "GET", "/", [], "")

      {largest_chunk, received, _chunks} = drain(connection, 0, 0, 0)

      assert received == @body_bytes
      # `buffer` bounds the ciphertext read, so a record carried over from the
      # previous read can be delivered alongside it. The documented allowance is
      # one TLS record.
      assert largest_chunk <= @receive_cap + 16_384

      _ = Task.shutdown(server, 5_000)
      :ssl.close(listener)
    end

    # The receive ceiling rests on two Mint behaviours that no assertion about
    # the adapter's own output would notice changing. If either moves under a
    # dependency bump, this fails first and says which.
    test "pins the Mint behaviour the receive ceiling depends on" do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, {_address, port}} = :inet.sockname(listener)

      parent = self()

      # The acceptor has to outlive the assertions. When it exits it closes the
      # sockets it owns, and `:inet.getopts/2` on the closed peer of one of them
      # answers `{:error, :einval}` instead of the option.
      acceptor =
        Task.async(fn ->
          accepted = Enum.map(1..2, fn _ -> :gen_tcp.accept(listener, 2_000) end)
          send(parent, :accepted)

          receive do
            :release -> Enum.each(accepted, fn {:ok, socket} -> :gen_tcp.close(socket) end)
          end
        end)

      {:ok, passive} =
        Mint.HTTP.connect(:http, "127.0.0.1", port,
          protocols: [:http1],
          mode: :passive,
          transport_opts: [buffer: @receive_cap]
        )

      {:ok, active} =
        Mint.HTTP.connect(:http, "127.0.0.1", port,
          protocols: [:http1],
          transport_opts: [buffer: @receive_cap]
        )

      assert_receive :accepted, 5_000

      # 1. Mint.Core.Util.inet_opts/2 raises `buffer` to max(buffer, sndbuf,
      #    recbuf) on every initiate/5, so :transport_opts cannot carry the
      #    ceiling and it has to be applied to the connected socket.
      assert {:ok, [buffer: raised]} =
               :inet.getopts(Mint.HTTP.get_socket(passive), [:buffer])

      assert raised > @receive_cap

      # 2. Only passive mode leaves the socket unarmed. That is what lets the
      #    ceiling be applied before any read can be serviced under the raised
      #    buffer above.
      assert {:ok, [active: false]} =
               :inet.getopts(Mint.HTTP.get_socket(passive), [:active])

      assert {:ok, [active: :once]} =
               :inet.getopts(Mint.HTTP.get_socket(active), [:active])

      send(acceptor.pid, :release)
      _ = Task.shutdown(acceptor, 2_000)
      Mint.HTTP.close(passive)
      Mint.HTTP.close(active)
      :gen_tcp.close(listener)
    end

    test "refuses a peer that never completes a status line" do
      # Mint buffers an unterminated status line with no ceiling of its own, and
      # emits no response, so neither the body nor the header ceiling can see it.
      assert_refused_before_parsing("HTTP/1.1 200 ")
    end

    test "refuses a peer that never completes a chunk-size line" do
      assert_refused_before_parsing("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
    end

    test "refuses a peer that never completes a chunk extension" do
      assert_refused_before_parsing("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5;")
    end

    test "rejects a receive ceiling outside a whole number of TLS records" do
      for invalid <- [20_000, 8_192, 0, -16_384, 1_048_576 + 16_384] do
        assert {:error, :invalid_request, :not_dispatched} =
                 MCPHTTPAdapter.request(
                   method: :get,
                   url: "http://127.0.0.1:1/",
                   timeout_ms: 1_000,
                   max_receive_bytes: invalid
                 ),
               "expected #{invalid} to be refused"
      end
    end

    # The exact value of the pending ceiling is the whole slice, so it gets a
    # two-sided test. A peer stalling at exactly the ceiling is still waited
    # for and ends at the clock; one byte more is refused by the ceiling.
    # Without both sides, every arithmetic change to `max_pending_bytes`
    # survives. Neither side sends a completing response, because the peer
    # cannot control which socket message it would land in.
    test "admits a stall of exactly the pending ceiling and refuses one byte more" do
      assert {:error, :timeout, :possibly_dispatched} = stall_of(0)
      assert {:error, :response_exceeded, :possibly_dispatched} = stall_of(1)
    end

    # A legitimate chunked body costs about six bytes of framing per chunk. A
    # cumulative wire ceiling would refuse this; a ceiling that resets on parse
    # progress does not. The body here is 20x the pending ceiling and arrives in
    # chunks small enough that framing alone exceeds it.
    test "serves a chunked body whose framing overhead exceeds the pending ceiling" do
      chunk = String.duplicate("y", 64)
      chunks = 8_192
      pending_ceiling = 1_024 + @receive_cap + 16_384

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, {_address, port}} = :inet.sockname(listener)

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

          :ok =
            :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")

          body = String.duplicate("40\r\n" <> chunk <> "\r\n", chunks)
          :ok = :gen_tcp.send(socket, body <> "0\r\n\r\n")
          :gen_tcp.close(socket)
        end)

      framing = chunks * 6
      assert framing > pending_ceiling, "the peer must out-frame the ceiling to test it"

      assert {:ok, %{status: 200} = response} =
               MCPHTTPAdapter.request(
                 method: :get,
                 url: "http://127.0.0.1:#{port}/",
                 timeout_ms: 10_000,
                 max_body_bytes: byte_size(chunk) * chunks,
                 max_header_bytes: 1_024,
                 max_receive_bytes: @receive_cap
               )

      assert byte_size(response.body) == byte_size(chunk) * chunks

      _ = Task.shutdown(server, 2_000)
      :gen_tcp.close(listener)
    end

    # A peer that sends exactly the pending ceiling plus `overshoot` bytes of an
    # unterminated status line, and then holds the socket open sending nothing.
    defp stall_of(overshoot) do
      header_cap = 1_024
      stall = header_cap + @receive_cap + 16_384 + overshoot

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, {_address, port}} = :inet.sockname(listener)
      parent = self()

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
          :ok = :gen_tcp.send(socket, "HTTP/1.1 200 " <> :binary.copy(<<?O>>, stall - 13))
          send(parent, :sent)

          receive do
            :release -> :gen_tcp.close(socket)
          end
        end)

      result =
        MCPHTTPAdapter.request(
          method: :get,
          url: "http://127.0.0.1:#{port}/",
          timeout_ms: 750,
          max_header_bytes: header_cap,
          max_receive_bytes: @receive_cap
        )

      assert_receive :sent, 5_000
      send(server.pid, :release)
      _ = Task.shutdown(server, 2_000)
      :gen_tcp.close(listener)
      result
    end

    # The peer sends `preamble` and then more bytes than the pending ceiling
    # admits, and then stops without closing. A bounded adapter answers from the
    # ceiling; an unbounded one has nothing to answer from but the clock.
    defp assert_refused_before_parsing(preamble) do
      body_cap = 1_024
      header_cap = 1_024
      ceiling = header_cap + @receive_cap + 16_384

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, {_address, port}} = :inet.sockname(listener)
      parent = self()

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
          :ok = :gen_tcp.send(socket, preamble)
          :ok = :gen_tcp.send(socket, :binary.copy(<<?a>>, 2 * ceiling))
          send(parent, :sent)
          # Hold the socket open: a close would end the wait on its own.
          receive do
            :release -> :gen_tcp.close(socket)
          end
        end)

      result =
        MCPHTTPAdapter.request(
          method: :get,
          url: "http://127.0.0.1:#{port}/",
          timeout_ms: 5_000,
          max_body_bytes: body_cap,
          max_header_bytes: header_cap,
          max_receive_bytes: @receive_cap
        )

      assert_receive :sent, 5_000
      assert result == {:error, :response_exceeded, :possibly_dispatched}

      send(server.pid, :release)
      _ = Task.shutdown(server, 2_000)
      :gen_tcp.close(listener)
    end

    defp drain(connection, largest_chunk, received, chunks) do
      receive do
        message ->
          case Mint.HTTP.stream(connection, message) do
            {:ok, connection, responses} ->
              {largest_chunk, received, chunks, done?} =
                Enum.reduce(responses, {largest_chunk, received, chunks, false}, fn
                  {:data, _ref, data}, {largest, total, count, done?} ->
                    {max(largest, byte_size(data)), total + byte_size(data), count + 1, done?}

                  {:done, _ref}, {largest, total, count, _done?} ->
                    {largest, total, count, true}

                  _other, accumulator ->
                    accumulator
                end)

              if done?,
                do: {largest_chunk, received, chunks},
                else: drain(connection, largest_chunk, received, chunks)

            {:error, _connection, reason, _responses} ->
              flunk("TLS stream failed: #{inspect(reason)}")

            :unknown ->
              drain(connection, largest_chunk, received, chunks)
          end
      after
        10_000 -> flunk("TLS response did not complete")
      end
    end

    defp record_chunk(response, data) do
      {:cont,
       response
       |> Map.update(:received, byte_size(data), &(&1 + byte_size(data)))
       |> Map.update(:largest_chunk, byte_size(data), &max(&1, byte_size(data)))
       |> Map.update(:chunks, 1, &(&1 + 1))
       |> Map.put(:body, "")}
    end
  end
end
