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

  Phase 1 ships the envelope shape only; the success and error
  payloads inside it are stubbed (`tools/call` returns a fixed
  `runtime_error` envelope) until Phase 2 wires `Lisp.run/2`. Unknown
  tool names return an `unknown_tool` error per the D1 deviation
  (§ 7.4).
  """

  @phase_1_stub_message "phase 1 stub"
  @phase_1_stub_feedback "phase 1 stub — execution wiring lands in phase 2"

  @typedoc "MCP tool result envelope, ready for JSON-RPC serialization."
  @type t :: %{
          required(String.t()) => boolean() | map() | [map()]
        }

  @doc """
  Build the Phase 1 stubbed `tools/call` envelope for the
  `ptc_lisp_execute` tool.

  Returns a fixed R23 `runtime_error` payload wrapped in the MCP
  envelope. Phase 2 replaces this with real `Lisp.run/2` wiring.
  """
  @spec phase_1_stub() :: t()
  def phase_1_stub do
    payload = %{
      "status" => "error",
      "reason" => "runtime_error",
      "message" => @phase_1_stub_message,
      "feedback" => @phase_1_stub_feedback
    }

    error_envelope(payload)
  end

  @doc """
  Build the `unknown_tool` envelope for any `tools/call` whose
  `params.name` is not `"ptc_lisp_execute"`.

  Per § 7.4 D1, unknown tool names are surfaced as a tool result, not
  as JSON-RPC `-32602`.
  """
  @spec unknown_tool(String.t()) :: t()
  def unknown_tool(name) when is_binary(name) do
    payload = %{
      "status" => "error",
      "reason" => "unknown_tool",
      "message" => "unknown tool: #{name}",
      "feedback" =>
        "The MCP server exposes exactly one tool: `ptc_lisp_execute`. " <>
          "The requested tool `#{name}` is not registered."
    }

    error_envelope(payload)
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
