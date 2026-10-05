defmodule PtcRunner.TestSupport.MCPTLSProxy do
  @moduledoc false
  alias PtcRunner.TestSupport.TLSFixture

  # Exercise host-installed static credentials over real TLS without relaxing
  # the production HTTPS or certificate-verification contract.
  def start(dir, endpoint) do
    config =
      TLSFixture.server_config([
        {:Extension, {2, 5, 29, 17}, false, [{:iPAddress, <<127, 0, 0, 1>>}]}
      ])

    ca = Path.join(dir, "fixture-ca.pem")

    File.write!(
      ca,
      :public_key.pem_encode(
        Enum.map(config[:cacerts], &{:Certificate, cert_der(&1), :not_encrypted})
      )
    )

    original = :public_key.cacerts_get()
    trust = Path.join(dir, "fixture-trust.pem")

    File.write!(
      trust,
      :public_key.pem_encode(Enum.map(original, &{:Certificate, cert_der(&1), :not_encrypted}))
    )

    _ = :public_key.cacerts_clear()
    :ok = :public_key.cacerts_load(String.to_charlist(ca))

    {:ok, listener} =
      :ssl.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}] ++ config)

    {:ok, {_, port}} = :ssl.sockname(listener)
    upstream_port = URI.parse(endpoint).port
    {:ok, acceptor} = Task.start(fn -> accept(listener, upstream_port) end)

    %{
      endpoint: "https://127.0.0.1:#{port}/mcp",
      close: fn ->
        :ssl.close(listener)
        Process.exit(acceptor, :kill)
        _ = :public_key.cacerts_clear()
        :ok = :public_key.cacerts_load(String.to_charlist(trust))
      end
    }
  end

  defp cert_der({:cert, der, _}), do: der
  defp cert_der(der) when is_binary(der), do: der

  defp accept(listener, port) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        {:ok, worker} =
          Task.start(fn ->
            receive do
              {:socket, socket} -> forward(socket, port)
            end
          end)

        :ok = :ssl.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept(listener, port)

      {:error, :closed} ->
        :ok
    end
  end

  defp forward(socket, port) do
    with {:ok, socket} <- :ssl.handshake(socket, 5_000),
         {:ok, upstream} <- :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true]),
         :ok <- :ssl.setopts(socket, active: true) do
      relay(upstream, socket)
      :gen_tcp.close(upstream)
    end

    :ssl.close(socket)
  end

  defp relay(upstream, socket) do
    receive do
      {:ssl, ^socket, bytes} ->
        :gen_tcp.send(upstream, bytes)
        relay(upstream, socket)

      {:tcp, ^upstream, bytes} ->
        :ssl.send(socket, bytes)
        relay(upstream, socket)

      {:tcp_closed, ^upstream} ->
        :ok

      {:ssl_closed, ^socket} ->
        :ok

      {:tcp_error, ^upstream, _} ->
        :ok

      {:ssl_error, ^socket, _} ->
        :ok
    end
  end
end
