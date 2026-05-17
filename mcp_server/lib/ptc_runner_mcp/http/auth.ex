defmodule PtcRunnerMcp.Http.Auth do
  @moduledoc false

  @www_authenticate "Bearer"

  @type owner :: %{id: String.t(), hash: String.t()}

  @spec authenticate(Plug.Conn.t(), map()) :: {:ok, owner()} | {:error, :missing | :invalid}
  def authenticate(_conn, %{auth_disabled: true}) do
    {:ok, owner_for("disabled")}
  end

  def authenticate(conn, %{auth_token: token}) when is_binary(token) do
    with ["Bearer " <> presented] <- Plug.Conn.get_req_header(conn, "authorization"),
         true <- constant_time_equal(presented, token) do
      {:ok, owner_for(token)}
    else
      [] -> {:error, :missing}
      _ -> {:error, :invalid}
    end
  end

  def authenticate(_conn, _cfg), do: {:ok, owner_for("loopback-unauthenticated")}

  @spec challenge(:missing | :invalid) :: {integer(), String.t()}
  def challenge(:missing), do: {401, @www_authenticate}
  def challenge(:invalid), do: {401, ~s(Bearer error="invalid_token")}

  @spec owner_for(String.t()) :: owner()
  def owner_for(value) when is_binary(value) do
    hash = :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
    %{id: hash, hash: String.slice(hash, 0, 16)}
  end

  defp constant_time_equal(a, b) when is_binary(a) and is_binary(b) do
    Plug.Crypto.secure_compare(a, b)
  rescue
    _ -> false
  end
end
