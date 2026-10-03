defmodule PtcViewer.LiveSecurity do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2]

  @minimum_token_bytes 32
  alias PtcViewer.RequestSecurity

  def validate_token(nil), do: :ok

  def validate_token(token) when is_binary(token) and byte_size(token) >= @minimum_token_bytes,
    do: :ok

  def validate_token(_token), do: {:error, :invalid_live_token}

  def token_digest(nil), do: nil
  def token_digest(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  def nonce, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  def browser_request?(conn), do: RequestSecurity.valid_host?(conn)

  def browser_control_request?(conn, token_digest) do
    browser_request?(conn) and
      (loopback?(conn.remote_ip) or reporter_request?(conn, token_digest) or
         query_token?(conn, token_digest))
  end

  def browser_mutation?(conn, nonce, token_digest) when is_binary(nonce) do
    browser_request?(conn) and authenticated_browser_peer?(conn, token_digest) and
      RequestSecurity.valid_origin?(conn) and
      secure_equal(exact_header(conn, "x-ptc-viewer-live-nonce"), nonce)
  end

  def browser_mutation?(_conn, _nonce, _token_digest), do: false

  def reporter_request?(conn, nil), do: loopback?(conn.remote_ip)

  def reporter_request?(conn, token_digest) when is_binary(token_digest) do
    case exact_header(conn, "authorization") do
      "Bearer " <> token -> secure_equal(:crypto.hash(:sha256, token), token_digest)
      _missing_or_invalid -> false
    end
  end

  defp authenticated_browser_peer?(conn, token_digest),
    do: loopback?(conn.remote_ip) or reporter_request?(conn, token_digest)

  # Native EventSource cannot send Authorization. Keep URL credentials only
  # for the page bootstrap and its SSE connection, never for mutations.
  defp query_token?(%{method: "GET", request_path: path} = conn, token_digest)
       when path in ["/", "/api/live/stream"] and is_binary(token_digest) do
    tokens =
      conn.query_string
      |> URI.query_decoder()
      |> Enum.flat_map(fn
        {"live_token", token} -> [token]
        _other -> []
      end)

    case tokens do
      [token] -> secure_equal(:crypto.hash(:sha256, token), token_digest)
      _missing_or_ambiguous -> false
    end
  rescue
    _invalid_query -> false
  end

  defp query_token?(_conn, _token_digest), do: false

  defp exact_header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _invalid -> nil
    end
  end

  defp loopback?({127, _b, _c, _d}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_ip), do: false

  defp secure_equal(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal(_left, _right), do: false
end
