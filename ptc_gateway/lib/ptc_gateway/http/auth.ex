defmodule PtcGateway.HTTP.Auth do
  @moduledoc """
  Bearer comparison for the HTTP gateway.

  The companion receives an already-validated token from the host. Comparison
  is `Plug.Crypto.secure_compare/2` and nothing else. The `Authorization`
  scheme is matched case-insensitively per RFC 6750. The gateway never logs
  the token and never keeps it in plug options or process status. Bandit
  request `:start` and `:exception` telemetry still include the raw
  `Authorization` header because Bandit emits those events before the plug
  runs; `:stop` uses the stripped connection.
  """

  @spec presented(Plug.Conn.t()) :: {:ok, binary()} | :error
  def presented(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [header] -> bearer_token(header)
      _other -> :error
    end
  end

  def presented(_conn), do: :error

  @spec matches?(binary(), binary()) :: boolean()
  def matches?(presented, expected)
      when is_binary(presented) and is_binary(expected) and expected != "" do
    byte_size(presented) == byte_size(expected) and
      Plug.Crypto.secure_compare(presented, expected)
  end

  def matches?(_presented, _expected), do: false

  defp bearer_token(header) when is_binary(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, presented] ->
        if String.downcase(scheme, :ascii) == "bearer" and presented != "" do
          {:ok, presented}
        else
          :error
        end

      _other ->
        :error
    end
  end
end
