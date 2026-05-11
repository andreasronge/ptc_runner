defmodule PtcRunnerMcp.Upstream do
  @moduledoc """
  Behaviour implemented by MCP upstream connection processes.

  Both the Phase 1a in-process `PtcRunnerMcp.Upstream.Fake` and the
  Phase 1b stdio implementation conform to this behaviour so the
  Phase 2 swap is a Registry-level configuration change with no shape
  change on the integration surface.

  Per `Plans/ptc-runner-mcp-aggregator.md` §6.3:

    * `start_link/2` MUST complete the MCP handshake (`initialize`,
      `notifications/initialized`, `tools/list`) before returning
      `:ok`, or return `:error` with reason `:upstream_unavailable`
      and a detail string suitable for envelope reporting.
    * `call/4` MUST enforce both `:timeout` and `:max_response_bytes`,
      rejecting oversized responses **before** JSON decode where the
      wire format permits.
    * `call/4` MUST NOT raise; all failures are
      `{:error, reason, detail}`.
    * `stop/1` MUST be idempotent.
  """

  @typedoc ~s|The configured upstream name (e.g. "github", "linear").|
  @type server_name :: String.t()

  @typedoc "An upstream tool name (within the upstream's namespace)."
  @type tool_name :: String.t()

  @typedoc """
  JSON-encodable Elixir term as decoded by `Jason.decode/1`. Mirrors
  the PTC-Lisp/JSON convention: only `nil` / boolean / number /
  binary / list / string-keyed map.
  """
  @type json ::
          nil
          | boolean()
          | number()
          | binary()
          | [json]
          | %{optional(binary()) => json}

  @typedoc """
  Closed set of failure reasons surfaced to the program through
  the `upstream_calls` collector and (as `nil`) to PTC-Lisp.
  """
  @type reason ::
          :upstream_unavailable
          | :upstream_error
          | :timeout
          | :response_too_large

  @typedoc "Tool schema as returned by an upstream's `tools/list`."
  @type tool_schema :: %{
          required(:name) => String.t(),
          required(:input_schema) => map(),
          optional(:description) => String.t(),
          optional(:output_schema) => map(),
          optional(:annotations) => map()
        }

  @typedoc "Per-call options threaded through from `Limits`."
  @type call_opts :: [
          timeout: pos_integer(),
          max_response_bytes: pos_integer()
        ]

  @callback start_link(server_name(), config :: map()) :: GenServer.on_start()

  @callback list_tools(server_name()) ::
              {:ok, [tool_schema()]} | {:error, reason(), String.t()}

  @callback call(server_name(), tool_name(), args :: map(), call_opts()) ::
              {:ok, json()} | {:error, reason(), String.t()}

  @callback stop(server_name()) :: :ok
end
