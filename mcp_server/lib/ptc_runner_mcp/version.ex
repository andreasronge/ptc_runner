defmodule PtcRunnerMcp.Version do
  @moduledoc """
  MCP protocol version negotiation.

  Per `Plans/ptc-runner-mcp-server.md` § 7.1 and § 7.3, this server
  supports two MCP protocol revisions:

    * `"2025-11-25"` — primary (latest at v1).
    * `"2025-06-18"` — compatibility floor (first revision with the
      wire features this server depends on).

  Negotiation:

    * If the client advertises a supported revision, the server replies
      with the same revision.
    * Any other client value falls back to the server's primary
      (`"2025-11-25"`).
  """

  @primary "2025-11-25"
  @floor "2025-06-18"
  @supported [@primary, @floor]

  @doc "Server's primary (latest) supported protocol version."
  @spec primary() :: String.t()
  def primary, do: @primary

  @doc "Server's compatibility floor."
  @spec floor() :: String.t()
  def floor, do: @floor

  @doc "List of all client `protocolVersion` values negotiated to themselves."
  @spec supported() :: [String.t()]
  def supported, do: @supported

  @doc """
  Pick the server's reply `protocolVersion` for a given client request.

  Stashes the negotiated version in `:persistent_term` as a side effect
  so downstream code (e.g. per-call telemetry under § 6.7) can read
  the most recently negotiated revision via `negotiated/0`.

  ## Examples

      iex> PtcRunnerMcp.Version.negotiate("2025-11-25")
      "2025-11-25"

      iex> PtcRunnerMcp.Version.negotiate("2025-06-18")
      "2025-06-18"

      iex> PtcRunnerMcp.Version.negotiate("1999-01-01")
      "2025-11-25"

      iex> PtcRunnerMcp.Version.negotiate(nil)
      "2025-11-25"
  """
  @spec negotiate(term()) :: String.t()
  def negotiate(version) do
    chosen =
      case version do
        v when v in @supported -> v
        _ -> @primary
      end

    :persistent_term.put({__MODULE__, :negotiated}, chosen)
    chosen
  end

  @doc """
  Most recently negotiated protocol version (defaults to `primary/0`
  before any `initialize` request lands).
  """
  @spec negotiated() :: String.t()
  def negotiated do
    :persistent_term.get({__MODULE__, :negotiated}, @primary)
  end

  @doc "The package version (`mix.exs` `@version`)."
  @spec package_version() :: String.t()
  def package_version do
    case :application.get_key(:ptc_runner_mcp, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      :undefined -> "0.0.0"
    end
  end
end
