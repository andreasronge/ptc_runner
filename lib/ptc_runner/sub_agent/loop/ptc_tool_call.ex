defmodule PtcRunner.SubAgent.Loop.PtcToolCall do
  @moduledoc """
  Native tool-call transport plumbing for `ptc_transport: :tool_call` agents.

  Phase 3 scope (this file): expose the OpenAI-format tool schema for the
  single internal native tool, `ptc_lisp_execute`. App tools are never
  exposed as provider-native tools in `:tool_call` mode — they remain
  callable only from inside a PTC-Lisp program via `(tool/name ...)`. The
  system prompt continues to render the full app-tool inventory.

  Later phases will fill in the loop branch, success / error tool-result
  rendering, protocol-error handling, and `*1`/`*2`/`*3` history tied to
  successful intermediate executions.

  See `Plans/ptc-lisp-tool-call-transport.md` for the full design and the
  Two Tool Layers conceptual model.

  ## Naming

  In this module, "tool call" without qualifier refers to a *native* tool
  call (the `ptc_lisp_execute` invocation on the provider wire). PTC-Lisp
  `(tool/...)` invocations continue to be called "app tool calls" and
  surface as `lisp_step.tool_calls`.
  """

  @ptc_lisp_execute_name "ptc_lisp_execute"

  # Canonical description string — single source of truth referenced by
  # R7 and the Two Tool Layers section of the plan. Tests assert stable
  # substrings against this constant; do not paraphrase elsewhere.
  @ptc_lisp_execute_description "Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation and tool orchestration. Call app tools as `(tool/name ...)` from inside the program — do not attempt to call app tools as native function calls; only `ptc_lisp_execute` is available natively."

  @doc """
  The reserved native tool name (`"ptc_lisp_execute"`).
  """
  @spec tool_name() :: String.t()
  def tool_name, do: @ptc_lisp_execute_name

  @doc """
  The canonical description string for the `ptc_lisp_execute` tool.

  This is the single source of truth — tests assert stable substrings
  against this value. Do not paraphrase the guidance elsewhere.
  """
  @spec tool_description() :: String.t()
  def tool_description, do: @ptc_lisp_execute_description

  @doc """
  Build the OpenAI-format tool schema for `ptc_lisp_execute`.

  Returns a single map. The intended use in `:tool_call` mode is to put
  exactly this one entry in the LLM request's `tools` field — app tools
  are never included.

  ## Examples

      iex> schema = PtcRunner.SubAgent.Loop.PtcToolCall.tool_schema()
      iex> schema["type"]
      "function"
      iex> schema["function"]["name"]
      "ptc_lisp_execute"
      iex> schema["function"]["parameters"]["required"]
      ["program"]

  """
  @spec tool_schema() :: map()
  def tool_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => @ptc_lisp_execute_name,
        "description" => @ptc_lisp_execute_description,
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "program" => %{
              "type" => "string",
              "description" =>
                "PTC-Lisp source code. Must be non-empty. Call app tools as `(tool/name ...)` from inside the program."
            }
          },
          "required" => ["program"],
          "additionalProperties" => false
        }
      }
    }
  end

  @doc """
  Build the request `tools` list for an agent.

  In `:tool_call` mode, returns exactly one entry — the
  `ptc_lisp_execute` schema — regardless of how many app tools the agent
  declares. App tools stay in the system prompt's Tool Inventory and are
  callable only from inside the sandboxed program.

  In `:content` mode, returns `nil` so the request omits the `tools`
  field (matching today's behavior where PTC-Lisp app tools are not
  exposed as native provider tools).
  """
  @spec request_tools(PtcRunner.SubAgent.Definition.t()) :: [map()] | nil
  def request_tools(%{ptc_transport: :tool_call}), do: [tool_schema()]
  def request_tools(_agent), do: nil
end
