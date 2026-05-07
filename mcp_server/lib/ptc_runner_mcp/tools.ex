defmodule PtcRunnerMcp.Tools do
  @moduledoc """
  `tools/list` and `tools/call` handlers.

  Per `Plans/ptc-runner-mcp-server.md` § 8.1, the server advertises
  exactly one tool, `ptc_lisp_execute`. The advertised description is
  the canonical `:mcp_no_tools` profile string from
  `PtcRunner.PtcToolProtocol`, followed by exactly two newlines, then
  the package-owned authoring card (§ 8.4).

  Phase 1's `tools/call` is a stub — see `PtcRunnerMcp.Envelope`. Real
  `Lisp.run/2` wiring lands in Phase 2.
  """

  alias PtcRunner.PtcToolProtocol
  alias PtcRunnerMcp.Envelope

  @tool_name "ptc_lisp_execute"

  # Compile-time read of the authoring card per § 8.4. The
  # `@external_resource` attribute tells BEAM to recompile this module
  # whenever the file changes. We resolve the path relative to this
  # source file rather than via `:code.priv_dir/1` because the app may
  # not yet be loaded at compile time.
  @priv_path Path.expand(Path.join([__DIR__, "..", "..", "priv", "mcp_authoring_card.md"]))
  @external_resource @priv_path
  @authoring_card File.read!(@priv_path)

  @doc """
  The verbatim authoring-card markdown shipped at
  `mcp_server/priv/mcp_authoring_card.md`.

  Read at compile time via `@external_resource`; edits to the source
  file trigger a recompile of this module.
  """
  @spec authoring_card() :: String.t()
  def authoring_card, do: @authoring_card

  @doc """
  The advertised `description` field for the `ptc_lisp_execute` tool.

  Composed per § 8.4 as
  `tool_description(:mcp_no_tools) <> "\\n\\n" <> authoring_card()`.
  """
  @spec advertised_description() :: String.t()
  def advertised_description do
    PtcToolProtocol.tool_description(:mcp_no_tools) <> "\n\n" <> authoring_card()
  end

  @doc "The single tool entry returned in `tools/list`."
  @spec tool_entry() :: map()
  def tool_entry do
    %{
      "name" => @tool_name,
      "description" => advertised_description(),
      "inputSchema" => input_schema(),
      "annotations" => %{
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      }
    }
  end

  @doc "Handle a `tools/list` request. Always returns the single advertised tool."
  @spec list() :: map()
  def list, do: %{"tools" => [tool_entry()]}

  @doc """
  Handle a `tools/call` request.

  Phase 1 stub: any call to `ptc_lisp_execute` returns a fixed
  `runtime_error` envelope (`"phase 1 stub"`). Any other tool name
  returns an `unknown_tool` envelope per § 7.4 D1 (NOT JSON-RPC
  `-32601`).
  """
  @spec call(map()) :: map()
  def call(%{"name" => @tool_name}), do: Envelope.phase_1_stub()
  def call(%{"name" => name}) when is_binary(name), do: Envelope.unknown_tool(name)
  def call(_), do: Envelope.unknown_tool("")

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "program" => %{
          "type" => "string",
          "description" => "PTC-Lisp source code. Must be non-empty after trimming whitespace."
        },
        "context" => %{
          "type" => "object",
          "description" =>
            "Optional map of named values bound under data/ in the program. " <>
              "Keys are strings; values are JSON-encodable.",
          "additionalProperties" => true
        },
        "signature" => %{
          "type" => "string",
          "description" =>
            "Optional PTC signature for return validation, e.g. '() -> {count :int}'."
        }
      },
      "required" => ["program"]
    }
  end
end
