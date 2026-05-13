defmodule PtcRunnerMcp.Sessions.Owner do
  @moduledoc """
  Owner derivation and authorization helpers for PTC-Lisp sessions.

  Phase 1 uses a stdio-local owner. The map shape already accepts future HTTP
  owner data so the session state and registry do not need a later migration.
  """

  @type stdio_owner :: %{required(:transport) => :stdio, required(:instance_id) => String.t()}

  @type http_owner :: %{
          required(:transport) => :http,
          required(:mcp_session_id) => String.t(),
          optional(:client_id) => String.t() | nil,
          optional(:user_id) => String.t() | nil
        }

  @type t :: stdio_owner() | http_owner()

  @doc "Return the process-wide stdio owner."
  @spec stdio() :: stdio_owner()
  def stdio do
    %{transport: :stdio, instance_id: stdio_instance_id()}
  end

  @doc "Build a future HTTP owner map."
  @spec http(String.t(), keyword()) :: http_owner()
  def http(mcp_session_id, opts \\ []) when is_binary(mcp_session_id) do
    %{
      transport: :http,
      mcp_session_id: mcp_session_id,
      client_id: Keyword.get(opts, :client_id),
      user_id: Keyword.get(opts, :user_id)
    }
  end

  @doc """
  Derive an owner from a routing context.

  Accepted contexts:

    * `nil` or `%{}`: stdio owner.
    * `%{owner: owner}`: normalized explicit owner.
    * `%{transport: :stdio | "stdio", ...}`.
    * `%{transport: :http | "http", mcp_session_id: ...}`.
  """
  @spec from_context(nil | map() | keyword()) :: {:ok, t()} | {:error, :session_args_error}
  def from_context(nil), do: {:ok, stdio()}
  def from_context([]), do: {:ok, stdio()}

  def from_context(context) when is_list(context) do
    context |> Map.new() |> from_context()
  end

  def from_context(%{owner: owner}), do: normalize(owner)
  def from_context(%{"owner" => owner}), do: normalize(owner)

  def from_context(%{transport: transport} = context) do
    derive(transport, context)
  end

  def from_context(%{"transport" => transport} = context) do
    derive(transport, context)
  end

  def from_context(context) when is_map(context) and map_size(context) == 0, do: {:ok, stdio()}
  def from_context(_other), do: {:error, :session_args_error}

  @doc "Normalize and validate an owner map."
  @spec normalize(term()) :: {:ok, t()} | {:error, :session_args_error}
  def normalize(%{transport: :stdio, instance_id: id}) when is_binary(id) and id != "" do
    {:ok, %{transport: :stdio, instance_id: id}}
  end

  def normalize(%{"transport" => "stdio", "instance_id" => id}) when is_binary(id) and id != "" do
    {:ok, %{transport: :stdio, instance_id: id}}
  end

  def normalize(%{transport: :http, mcp_session_id: id} = owner)
      when is_binary(id) and id != "" do
    {:ok,
     %{
       transport: :http,
       mcp_session_id: id,
       client_id: Map.get(owner, :client_id),
       user_id: Map.get(owner, :user_id)
     }}
  end

  def normalize(%{"transport" => "http", "mcp_session_id" => id} = owner)
      when is_binary(id) and id != "" do
    {:ok,
     %{
       transport: :http,
       mcp_session_id: id,
       client_id: Map.get(owner, "client_id"),
       user_id: Map.get(owner, "user_id")
     }}
  end

  def normalize(_other), do: {:error, :session_args_error}

  @doc "Check whether the caller owns a session."
  @spec owner?(t(), t()) :: boolean()
  def owner?(expected, actual), do: expected == actual

  @doc false
  @spec same?(t(), t()) :: boolean()
  def same?(expected, actual), do: owner?(expected, actual)

  @doc false
  @spec hash(t()) :: non_neg_integer()
  def hash(owner) when is_map(owner), do: :erlang.phash2(owner)

  @doc "Return `:ok` for matching owners, otherwise a session error tuple."
  @spec check(t(), t()) :: :ok | {:error, :session_owner_mismatch}
  def check(expected, actual) do
    if owner?(expected, actual), do: :ok, else: {:error, :session_owner_mismatch}
  end

  @doc "Stable, non-secret owner fingerprint for registry indexes and telemetry."
  @spec fingerprint(t()) :: String.t()
  def fingerprint(owner) when is_map(owner) do
    owner
    |> :erlang.term_to_binary()
    |> :erlang.phash2()
    |> Integer.to_string(16)
  end

  defp derive(transport, context) when transport in [:stdio, "stdio"] do
    id = Map.get(context, :instance_id) || Map.get(context, "instance_id") || stdio_instance_id()
    normalize(%{transport: :stdio, instance_id: id})
  end

  defp derive(transport, context) when transport in [:http, "http"] do
    id = Map.get(context, :mcp_session_id) || Map.get(context, "mcp_session_id")

    normalize(%{
      transport: :http,
      mcp_session_id: id,
      client_id: Map.get(context, :client_id) || Map.get(context, "client_id"),
      user_id: Map.get(context, :user_id) || Map.get(context, "user_id")
    })
  end

  defp derive(_transport, _context), do: {:error, :session_args_error}

  defp stdio_instance_id do
    key = {__MODULE__, :stdio_instance_id}

    case :persistent_term.get(key, nil) do
      nil ->
        id = "stdio_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
        :persistent_term.put(key, id)
        id

      id ->
        id
    end
  end
end
