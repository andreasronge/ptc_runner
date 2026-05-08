defmodule PtcRunnerMcp.Envelope do
  @moduledoc """
  MCP `tools/call` result envelope.

  Per `Plans/ptc-runner-mcp-server.md` § 10.1, every tool result is
  returned as a JSON object with three keys:

    * `"isError"` — boolean, `true` for any R23 error including
      `(fail v)` (§ 10.5).
    * `"structuredContent"` — the parsed R22/R23 payload as an object.
    * `"content"` — a single-element array carrying the same payload
      as a `"text"` block, mirroring `structuredContent`.

  Phase 2 wires real `Lisp.run/2` results into the envelope. This
  module also owns `render_error/3` — the single entry point all MCP
  error rendering goes through. For the seven shared reasons it
  delegates to `PtcRunner.PtcToolProtocol.render_error/3`; for the
  two MCP-only reasons (`:busy`, `:unknown_tool`) it constructs the
  R23 payload locally per § 10.3.

  Per § 10.3, `:busy` and `:unknown_tool` are NOT in the shared
  `error_reason()` enum. `PtcRunner.PtcToolProtocol.render_error/3`
  is intentionally NOT widened to accept them; this package owns
  their rendering.
  """

  alias PtcRunner.PtcToolProtocol

  @shared_reasons [
    :parse_error,
    :runtime_error,
    :timeout,
    :memory_limit,
    :args_error,
    :fail,
    :validation_error
  ]

  @typedoc "MCP tool result envelope, ready for JSON-RPC serialization."
  @type t :: %{
          required(String.t()) => boolean() | map() | [map()]
        }

  @typedoc "Reasons accepted by `render_error/3`."
  @type reason ::
          :parse_error
          | :runtime_error
          | :timeout
          | :memory_limit
          | :args_error
          | :fail
          | :validation_error
          | :busy
          | :unknown_tool
          | :shutting_down

  @doc """
  Build the `unknown_tool` envelope for any `tools/call` whose
  `params.name` is not `"ptc_lisp_execute"`.

  Per § 7.4 D1, unknown tool names are surfaced as a tool result, not
  as JSON-RPC `-32602`. Delegates to `render_error/3` so all error
  rendering goes through one entry point.
  """
  @spec unknown_tool(String.t()) :: t()
  def unknown_tool(name) when is_binary(name) do
    render_error(:unknown_tool, "unknown tool: #{name}", tool_name: name)
  end

  @doc """
  Build a `busy` envelope when `:max_concurrent_calls` is exceeded.

  Convenience wrapper around `render_error(:busy, ...)`.
  """
  @spec busy(pos_integer()) :: t()
  def busy(cap) when is_integer(cap) and cap > 0 do
    render_error(:busy, "server busy: #{cap} concurrent calls in flight", cap: cap)
  end

  @doc """
  Build a `shutting_down` envelope for `tools/call` arriving after a
  `shutdown` request was accepted (§ 6.4 row 2).

  This is an MCP-only reason — it lives in `:ptc_runner_mcp` and is
  intentionally NOT added to `PtcRunner.PtcToolProtocol.error_reason()`.
  """
  @spec shutting_down() :: t()
  def shutting_down do
    render_error(
      :shutting_down,
      "server is draining after shutdown; new tool calls are rejected"
    )
  end

  @doc """
  Render an error tool-result envelope for any reason emitted by MCP v1.

  ## Reasons

    * Seven shared reasons (`:parse_error`, `:runtime_error`,
      `:timeout`, `:memory_limit`, `:args_error`, `:fail`,
      `:validation_error`) — delegated to
      `PtcRunner.PtcToolProtocol.render_error/3` and wrapped in the
      MCP envelope. Forwards `:result` and `:feedback` opts.
    * `:busy` — constructed locally with an MCP-owned feedback string.
      Accepts `:cap` for the in-flight cap.
    * `:unknown_tool` — constructed locally with an MCP-owned feedback
      string. Accepts `:tool_name` for the offending name.

  Both `:busy` and `:unknown_tool` produce R23 payloads with `status`,
  `reason`, `message`, and `feedback` only — never a `result` field
  (§ 10.3).
  """
  @spec render_error(reason(), String.t(), keyword()) :: t()
  def render_error(reason, message, opts \\ []) do
    reason
    |> render_error_payload(message, opts)
    |> error_envelope()
  end

  @doc """
  Render the **unwrapped** R23 structured payload for any reason.

  Phase 0 (`Plans/ptc-runner-mcp-aggregator.md` §11.3) seam: the
  request handler builds the v1 payload, may decorate it with
  `upstream_calls` (Phase 1a), and only then wraps it via
  `error_envelope/1`. Returning the bare map keeps the wrap step
  cleanly separable from the construction step.

  Same reason set and option semantics as `render_error/3`; this is
  exactly the function `render_error/3` delegates to.
  """
  @spec render_error_payload(reason(), String.t(), keyword()) :: map()
  def render_error_payload(reason, message, opts \\ [])

  def render_error_payload(reason, message, opts)
      when reason in @shared_reasons and is_binary(message) do
    reason
    |> PtcToolProtocol.render_error(message, opts)
    |> Jason.decode!()
  end

  def render_error_payload(:busy, message, opts) when is_binary(message) do
    cap = Keyword.get(opts, :cap)

    feedback =
      Keyword.get(opts, :feedback) ||
        "The MCP server is at its concurrent-call cap" <>
          if(is_integer(cap), do: " (#{cap})", else: "") <>
          ". The previous call has not finished. Wait briefly and retry the same `tools/call`."

    %{
      "status" => "error",
      "reason" => "busy",
      "message" => message,
      "feedback" => feedback
    }
  end

  def render_error_payload(:unknown_tool, message, opts) when is_binary(message) do
    name = Keyword.get(opts, :tool_name)

    feedback =
      Keyword.get(opts, :feedback) ||
        "The MCP server exposes exactly one tool: `ptc_lisp_execute`." <>
          if is_binary(name) and name != "" do
            " The requested tool `#{name}` is not registered."
          else
            " The requested tool name was missing or empty."
          end

    %{
      "status" => "error",
      "reason" => "unknown_tool",
      "message" => message,
      "feedback" => feedback
    }
  end

  def render_error_payload(:shutting_down, message, opts) when is_binary(message) do
    feedback =
      Keyword.get(opts, :feedback) ||
        "The MCP server received a `shutdown` request and is no " <>
          "longer accepting new tool calls. Open a fresh server " <>
          "process to retry."

    %{
      "status" => "error",
      "reason" => "shutting_down",
      "message" => message,
      "feedback" => feedback
    }
  end

  @doc "Wrap any structured payload as a successful MCP tool result."
  @spec success(map()) :: t()
  def success(structured) when is_map(structured) do
    %{
      "isError" => false,
      "structuredContent" => structured,
      "content" => [%{"type" => "text", "text" => Jason.encode!(structured)}]
    }
  end

  @doc "Wrap any structured payload as an error MCP tool result."
  @spec error_envelope(map()) :: t()
  def error_envelope(structured) when is_map(structured) do
    %{
      "isError" => true,
      "structuredContent" => structured,
      "content" => [%{"type" => "text", "text" => Jason.encode!(structured)}]
    }
  end
end
