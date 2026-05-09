defmodule PtcRunnerMcp.Upstream.Http.Session do
  @moduledoc """
  Streamable HTTP session state (MCP rev 2025-06-18).

  Tracks the negotiated protocol version, the optional `Mcp-Session-Id`
  the server returned on `initialize`, and helpers for header
  construction and JSON-RPC body shaping. Pure functions; the owning
  `Upstream.Http` GenServer (Phase 2D) threads the struct through its
  state.

  See `Plans/http-transport-credentials.md` §6.1 / §6.2 / §6.3 for the
  normative wire shape.

  ## Lifecycle

      session = Session.new()
      headers = Session.headers_for_initialize(session, [])
      body    = Session.initialize_body(session, %{"name" => "...", "version" => "..."})
      # POST → response
      {:ok, session} = Session.apply_initialize_response(session, response)
      # POST notifications/initialized → 202
      session = Session.apply_handshake_complete(session)
      # ... tools/list and beyond use Session.headers_for_post/2

  All header functions emit lowercase header names so the caller can
  pass them to `Req.post/2` without case-folding concerns. HTTP header
  names are case-insensitive on the wire (RFC 9110 §5.1) and Req/Finch
  preserve whatever the caller supplied.
  """

  @protocol_version "2025-06-18"

  @typedoc """
  Session state.

    * `handshake_complete?` — `true` only after
      `notifications/initialized` returned 202. Until then,
      `MCP-Protocol-Version` MUST be omitted (§6.1.1).

    * `session_id` — opaque session id captured from the
      `Mcp-Session-Id` response header on `initialize`. `nil` for
      stateless servers.

    * `negotiated_version` — echoed `MCP-Protocol-Version` header
      from the initialize response, or `nil` if the server didn't
      send one.

    * `next_id` — monotonically increasing JSON-RPC request id,
      starts at 1.
  """
  @type t :: %__MODULE__{
          handshake_complete?: boolean(),
          session_id: String.t() | nil,
          negotiated_version: String.t() | nil,
          next_id: integer()
        }

  defstruct handshake_complete?: false,
            session_id: nil,
            negotiated_version: nil,
            next_id: 1

  @typedoc "Shape passed into `apply_initialize_response/2`."
  @type initialize_response :: %{
          required(:status) => integer(),
          required(:headers) => [{String.t(), String.t()}],
          required(:body) => map()
        }

  # ----------------------------------------------------------------
  # Constructors / accessors
  # ----------------------------------------------------------------

  @doc """
  Returns a fresh session.

      iex> s = PtcRunnerMcp.Upstream.Http.Session.new()
      iex> s.handshake_complete?
      false
      iex> s.next_id
      1
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  The MCP protocol version this v1 implementation targets.

      iex> PtcRunnerMcp.Upstream.Http.Session.protocol_version()
      "2025-06-18"
  """
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc """
  Hand out a JSON-RPC request id and bump.

      iex> {id, s} = PtcRunnerMcp.Upstream.Http.Session.next_request_id(PtcRunnerMcp.Upstream.Http.Session.new())
      iex> id
      1
      iex> {id2, _} = PtcRunnerMcp.Upstream.Http.Session.next_request_id(s)
      iex> id2
      2
  """
  @spec next_request_id(t()) :: {integer(), t()}
  def next_request_id(%__MODULE__{next_id: n} = session) do
    {n, %{session | next_id: n + 1}}
  end

  # ----------------------------------------------------------------
  # Handshake
  # ----------------------------------------------------------------

  @doc """
  Validate an `initialize` response and update session state.

  Per §6.1.1, the server's `protocolVersion` MUST equal the version
  this impl targets ("2025-06-18"). Any other value fails the
  handshake.

  Captures `Mcp-Session-Id` from response headers (case-insensitive
  lookup; absent is OK — stateless server). Captures
  `MCP-Protocol-Version` echo header for `negotiated_version`.

  Returns `{:ok, session}` on success or `{:error, reason, detail}`
  on failure. The returned session has `handshake_complete?: false`
  — the caller must POST `notifications/initialized` and call
  `apply_handshake_complete/1` after the 202.
  """
  @spec apply_initialize_response(t(), initialize_response()) ::
          {:ok, t()} | {:error, atom(), String.t()}
  def apply_initialize_response(%__MODULE__{} = session, %{
        status: status,
        headers: headers,
        body: body
      })
      when is_integer(status) and is_list(headers) and is_map(body) do
    cond do
      status != 200 ->
        {:error, :upstream_unavailable, "initialize returned http #{status}"}

      not match?(%{"result" => %{"protocolVersion" => v}} when is_binary(v), body) ->
        {:error, :upstream_error,
         "initialize response missing result.protocolVersion: #{inspect_short(body)}"}

      true ->
        %{"result" => %{"protocolVersion" => version}} = body

        if version != @protocol_version do
          {:error, :upstream_unavailable,
           "protocol version mismatch: server=#{version} client=#{@protocol_version}"}
        else
          session = %{
            session
            | session_id: header_get(headers, "mcp-session-id"),
              negotiated_version: header_get(headers, "mcp-protocol-version") || version
          }

          {:ok, session}
        end
    end
  end

  @doc """
  Mark the handshake as complete after `notifications/initialized`
  returned 202.

      iex> s = PtcRunnerMcp.Upstream.Http.Session.new()
      iex> s = PtcRunnerMcp.Upstream.Http.Session.apply_handshake_complete(s)
      iex> s.handshake_complete?
      true
  """
  @spec apply_handshake_complete(t()) :: t()
  def apply_handshake_complete(%__MODULE__{} = session) do
    %{session | handshake_complete?: true}
  end

  @doc """
  `true` when the response status indicates session loss per §6.3.

  A 404 to a request that carried our held `Mcp-Session-Id` is the
  spec's session-loss signal. A 404 without a held session id is just
  a 404 (likely a misconfigured URL) — not session loss.

      iex> s = %PtcRunnerMcp.Upstream.Http.Session{session_id: "abc"}
      iex> PtcRunnerMcp.Upstream.Http.Session.session_lost?(s, %{status: 404})
      true
      iex> PtcRunnerMcp.Upstream.Http.Session.session_lost?(s, %{status: 200})
      false
      iex> s2 = %PtcRunnerMcp.Upstream.Http.Session{session_id: nil}
      iex> PtcRunnerMcp.Upstream.Http.Session.session_lost?(s2, %{status: 404})
      false
  """
  @spec session_lost?(t(), %{required(:status) => integer()}) :: boolean()
  def session_lost?(%__MODULE__{session_id: sid}, %{status: 404}) when is_binary(sid), do: true
  def session_lost?(%__MODULE__{}, _), do: false

  # ----------------------------------------------------------------
  # Headers
  # ----------------------------------------------------------------

  # Protocol-controlled headers — must never be supplied by static
  # config (`Application.@static_headers_denylist` rejects them at
  # config-load). We strip them defensively from the `extra` list
  # too so a future loader bypass cannot smuggle them through.
  @protocol_controlled_headers ~w(
    mcp-protocol-version
    mcp-session-id
    user-agent
    content-type
    accept
  )

  @doc """
  Headers for the `initialize` POST.

  Per §6.1.1, `MCP-Protocol-Version` MUST be omitted on the
  initialize request itself (the version is negotiated via the body).
  `Mcp-Session-Id` is also omitted — there is no session id yet.

  Caller-supplied (static) headers are appended last; any extra that
  collides case-insensitively with a protocol-controlled name is
  dropped (belt-and-suspenders against a config-loader bypass —
  `Application.@static_headers_denylist` is the primary defence).
  """
  @spec headers_for_initialize(t(), [{String.t(), String.t()}]) ::
          [{String.t(), String.t()}]
  def headers_for_initialize(%__MODULE__{}, extra) when is_list(extra) do
    base_headers() ++ filter_protocol_controlled(extra)
  end

  @doc """
  Headers for any POST after the `initialize` exchange completes.

  Always includes `MCP-Protocol-Version`. Includes `Mcp-Session-Id`
  if and only if the server returned one on `initialize`. Strips any
  caller-supplied header that collides with a protocol-controlled
  name (defence-in-depth — the config loader rejects them upstream).
  """
  @spec headers_for_post(t(), [{String.t(), String.t()}]) ::
          [{String.t(), String.t()}]
  def headers_for_post(%__MODULE__{session_id: sid}, extra) when is_list(extra) do
    headers = base_headers() ++ [{"mcp-protocol-version", @protocol_version}]

    headers =
      case sid do
        nil -> headers
        s when is_binary(s) -> headers ++ [{"mcp-session-id", s}]
      end

    headers ++ filter_protocol_controlled(extra)
  end

  defp base_headers do
    [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"}
    ]
  end

  defp filter_protocol_controlled(extra) when is_list(extra) do
    Enum.reject(extra, fn
      {k, _v} when is_binary(k) -> String.downcase(k) in @protocol_controlled_headers
      _ -> false
    end)
  end

  # ----------------------------------------------------------------
  # JSON-RPC body shapes
  # ----------------------------------------------------------------

  @doc """
  Build the JSON-RPC `initialize` request body.

  Bumps `next_id` — returns the body, not the session, because the
  caller typically pairs this with `headers_for_initialize/2`. If the
  caller needs the new session, they can call `next_request_id/1`
  and `do_initialize_body/2` themselves; v1 doesn't expose that
  split because every initialize uses id `1` (the first id from a
  fresh session).

  `client_info` is a string-keyed map with `"name"` and `"version"`
  fields; the caller is responsible for supplying these.
  """
  @spec initialize_body(t(), map()) :: map()
  def initialize_body(%__MODULE__{} = session, client_info) when is_map(client_info) do
    {id, _} = next_request_id(session)

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => client_info
      }
    }
  end

  @doc """
  Build the JSON-RPC `notifications/initialized` body. No id field
  — JSON-RPC notifications carry no id (§6.2 step 2).
  """
  @spec notifications_initialized_body() :: map()
  def notifications_initialized_body do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{}
    }
  end

  @doc """
  Build the JSON-RPC `tools/list` request body.

  Bumps `next_id` and returns `{body, updated_session}` — unlike
  `initialize_body/2`, the caller MUST capture the updated session so
  subsequent requests use a fresh id.
  """
  @spec tools_list_body(t()) :: {map(), t()}
  def tools_list_body(%__MODULE__{} = session) do
    {id, session} = next_request_id(session)

    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/list",
      "params" => %{}
    }

    {body, session}
  end

  # ----------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------

  # Case-insensitive header lookup. HTTP header names are case-
  # insensitive (RFC 9110 §5.1); servers can send "Mcp-Session-Id",
  # "mcp-session-id", or "MCP-SESSION-ID" and we MUST accept all of
  # them.
  defp header_get(headers, target) when is_list(headers) and is_binary(target) do
    target_down = String.downcase(target)

    case Enum.find(headers, fn {k, _v} ->
           is_binary(k) and String.downcase(k) == target_down
         end) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp inspect_short(term), do: inspect(term, limit: 5, printable_limit: 80)
end
