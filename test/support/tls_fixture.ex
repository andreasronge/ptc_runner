defmodule PtcRunner.TestSupport.TLSFixture do
  @moduledoc """
  A loopback TLS listener for transport tests, minted in memory.

  `:public_key.pkix_test_data/1` builds the chain, so no certificate files are
  checked in and none are written at test time. Keys are RSA-2048 with SHA-256
  digests because the defaults are rejected by TLS 1.3 negotiation.
  """

  @doc """
  Starts a TLS listener on 127.0.0.1 and returns `{listener, port}`.
  """
  @spec listen() :: {:ssl.sslsocket(), :inet.port_number()}
  def listen do
    {:ok, listener} =
      :ssl.listen(
        0,
        [
          :binary,
          packet: :raw,
          active: false,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ] ++ server_config()
      )

    {:ok, {_address, port}} = :ssl.sockname(listener)
    {listener, port}
  end

  @doc """
  Accepts one connection and completes its handshake.
  """
  @spec accept(:ssl.sslsocket(), timeout()) :: {:ok, :ssl.sslsocket()} | {:error, term()}
  def accept(listener, timeout) do
    with {:ok, socket} <- :ssl.transport_accept(listener, timeout) do
      :ssl.handshake(socket, timeout)
    end
  end

  defp server_config do
    key = fn -> :public_key.generate_key({:rsa, 2048, 65_537}) end

    chain = %{
      root: [key: key.(), digest: :sha256],
      intermediates: [],
      peer: [key: key.(), digest: :sha256]
    }

    %{server_chain: chain, client_chain: chain}
    |> :public_key.pkix_test_data()
    |> Map.fetch!(:server_config)
  end
end
