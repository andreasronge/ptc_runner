defmodule PtcRunner.Kernel.MCPOAuth.TokenResponse do
  @moduledoc """
  Strict, bounded projection of OAuth token endpoint responses.

  Unknown members and identity tokens are discarded immediately. Only a valid
  bearer access token, optional authorized refresh token, bounded expiry, and
  exact scope set can enter private grant state.
  """

  alias PtcRunner.Kernel.MCPOAuth.Scope
  alias PtcRunner.Kernel.StrictJSON

  @max_body_bytes 65_536
  @max_token_bytes 8_192
  @max_error_bytes 256
  @max_expires_seconds 31_536_000
  @access_token ~r/\A[A-Za-z0-9\-._~+\/]+={0,}\z/
  @oauth_error ~r/\A[\x20-\x21\x23-\x5B\x5D-\x7E]+\z/

  @type grant_projection :: %{
          required(:access_token) => binary(),
          required(:token_type) => :bearer,
          required(:expires_in_ms) => pos_integer() | nil,
          required(:granted_scopes) => Scope.scope_set(),
          optional(:refresh_token) => binary()
        }

  @spec success(non_neg_integer(), [{binary(), binary()}], binary(), keyword()) ::
          {:ok, grant_projection()} | {:error, :invalid_token_response}
  def success(status, headers, body, opts)
      when is_integer(status) and is_list(headers) and is_binary(body) and is_list(opts) do
    with true <- Keyword.keys(opts) -- [:requested_scopes, :refresh_authorized] == [],
         %MapSet{} = requested <- Keyword.get(opts, :requested_scopes),
         refresh_authorized when is_boolean(refresh_authorized) <-
           Keyword.get(opts, :refresh_authorized, false),
         true <- status == 200,
         :ok <- json_media_type(headers),
         true <- byte_size(body) in 1..@max_body_bytes,
         {:ok, decoded} <- StrictJSON.decode(body),
         true <- is_map(decoded),
         {:ok, access_token} <- access_token(Map.get(decoded, "access_token")),
         :ok <- bearer_type(Map.get(decoded, "token_type")),
         {:ok, expires_in_ms} <- expires_in(Map.get(decoded, "expires_in")),
         {:ok, granted_scopes} <- granted_scopes(Map.get(decoded, "scope"), requested),
         true <- Scope.subset?(granted_scopes, requested),
         {:ok, refresh_token} <-
           projected_refresh_token(Map.get(decoded, "refresh_token"), refresh_authorized) do
      grant = %{
        access_token: access_token,
        token_type: :bearer,
        expires_in_ms: expires_in_ms,
        granted_scopes: granted_scopes
      }

      {:ok, maybe_put_refresh_token(grant, refresh_token)}
    else
      _invalid -> {:error, :invalid_token_response}
    end
  end

  def success(_status, _headers, _body, _opts), do: {:error, :invalid_token_response}

  @spec error(non_neg_integer(), [{binary(), binary()}], binary()) ::
          {:ok, binary()} | {:error, :invalid_token_response}
  def error(status, headers, body)
      when status in [400, 401] and is_list(headers) and is_binary(body) do
    with :ok <- json_media_type(headers),
         true <- byte_size(body) in 1..@max_body_bytes,
         {:ok, decoded} <- StrictJSON.decode(body),
         true <- is_map(decoded),
         error when is_binary(error) <- Map.get(decoded, "error"),
         true <- byte_size(error) in 1..@max_error_bytes and error =~ @oauth_error do
      {:ok, error}
    else
      _invalid -> {:error, :invalid_token_response}
    end
  end

  def error(_status, _headers, _body), do: {:error, :invalid_token_response}

  @spec access_token(term()) :: {:ok, binary()} | {:error, :invalid_access_token}
  def access_token(value)
      when is_binary(value) and byte_size(value) in 1..@max_token_bytes do
    if value =~ @access_token,
      do: {:ok, value},
      else: {:error, :invalid_access_token}
  end

  def access_token(_value), do: {:error, :invalid_access_token}

  @spec refresh_token(term()) :: {:ok, binary()} | {:error, :invalid_refresh_token}
  def refresh_token(value)
      when is_binary(value) and byte_size(value) in 1..@max_token_bytes do
    if Enum.all?(:binary.bin_to_list(value), &(&1 in 0x20..0x7E)),
      do: {:ok, value},
      else: {:error, :invalid_refresh_token}
  end

  def refresh_token(_value), do: {:error, :invalid_refresh_token}

  defp bearer_type(value) when is_binary(value) do
    if ascii_downcase(value) == "bearer",
      do: :ok,
      else: {:error, :invalid_token_type}
  end

  defp bearer_type(_value), do: {:error, :invalid_token_type}

  defp expires_in(nil), do: {:ok, nil}

  defp expires_in(value) when is_integer(value) and value in 1..@max_expires_seconds,
    do: {:ok, value * 1_000}

  defp expires_in(_value), do: {:error, :invalid_expires_in}

  defp granted_scopes(nil, requested), do: {:ok, requested}
  defp granted_scopes(value, _requested), do: Scope.parse_string(value)

  defp projected_refresh_token(nil, _authorized), do: {:ok, nil}
  defp projected_refresh_token(_value, false), do: {:ok, nil}
  defp projected_refresh_token(value, true), do: refresh_token(value)

  defp maybe_put_refresh_token(grant, nil), do: grant
  defp maybe_put_refresh_token(grant, token), do: Map.put(grant, :refresh_token, token)

  defp json_media_type(headers) do
    values =
      for {name, value} <- headers,
          ascii_downcase(name) == "content-type",
          do: value

    case values do
      [value] -> parse_json_media_type(value)
      _invalid -> {:error, :invalid_media_type}
    end
  end

  defp parse_json_media_type(value) when is_binary(value) do
    case value |> :binary.split(";", [:global]) |> Enum.map(&String.trim/1) do
      [type] ->
        if ascii_downcase(type) == "application/json",
          do: :ok,
          else: {:error, :invalid_media_type}

      [type, parameter] ->
        if ascii_downcase(type) == "application/json" and
             ascii_downcase(parameter) in ["charset=utf-8", "charset=\"utf-8\""] do
          :ok
        else
          {:error, :invalid_media_type}
        end

      _invalid ->
        {:error, :invalid_media_type}
    end
  end

  defp ascii_downcase(value) do
    for <<byte <- value>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end
end
