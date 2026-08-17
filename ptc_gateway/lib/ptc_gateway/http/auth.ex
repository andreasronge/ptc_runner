defmodule PtcGateway.HTTP.Auth do
  @moduledoc """
  Bearer comparison for the HTTP gateway.

  The companion receives an already-validated token from the host. Comparison
  is `Plug.Crypto.secure_compare/2` and nothing else; tokens are never logged.
  The `Authorization` scheme is matched case-insensitively per RFC 6750.
  """

  @spec authorized?(Plug.Conn.t(), binary()) :: boolean()
  def authorized?(%Plug.Conn{} = conn, expected) when is_binary(expected) and expected != "" do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [header] ->
        case bearer_token(header) do
          {:ok, presented} -> matches?(presented, expected)
          :error -> false
        end

      _other ->
        false
    end
  end

  def authorized?(_conn, _expected), do: false

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
