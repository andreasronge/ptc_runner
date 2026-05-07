defmodule PtcRunnerMcp.Tools do
  @moduledoc """
  `tools/list` and `tools/call` handlers.

  Per `Plans/ptc-runner-mcp-server.md` § 8.1, the server advertises
  exactly one tool, `ptc_lisp_execute`. The advertised description is
  the canonical `:mcp_no_tools` profile string from
  `PtcRunner.PtcToolProtocol`, followed by exactly two newlines, then
  the package-owned authoring card (§ 8.4).

  Phase 2 wires real `Lisp.run/2` execution through
  `PtcRunnerMcp.Sandbox` and enforces `:max_program_bytes` and
  `:max_concurrent_calls` (§ 11). `context` and `signature` arguments
  are still ignored in Phase 2 and land in Phase 3.
  """

  alias PtcRunner.PtcToolProtocol
  alias PtcRunnerMcp.{ConcurrencyGate, Envelope, Limits, Sandbox}

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

  For `name: "ptc_lisp_execute"`, validates the `program` argument per
  § 9.2 (must be a non-empty string, ≤ `:max_program_bytes`),
  acquires a permit from `PtcRunnerMcp.ConcurrencyGate`, and runs the
  program through `PtcRunnerMcp.Sandbox.execute/1`. When the cap is
  exceeded the call returns `:busy` synchronously (no queueing).

  For any other name, returns an `unknown_tool` envelope per § 7.4
  D1 (NOT JSON-RPC `-32601`).

  `context` and `signature` arguments are accepted at the schema
  level but ignored in Phase 2 — Phase 3 wires their semantics.
  """
  @spec call(map()) :: map()
  def call(%{"name" => @tool_name, "arguments" => args}) when is_map(args) do
    handle_execute(args)
  end

  def call(%{"name" => @tool_name}), do: handle_execute(%{})

  def call(%{"name" => name}) when is_binary(name), do: Envelope.unknown_tool(name)
  def call(_), do: Envelope.unknown_tool("")

  # ----------------------------------------------------------------
  # ptc_lisp_execute pipeline (§ 9.2 validation, § 11 semaphore)
  # ----------------------------------------------------------------

  defp handle_execute(args) do
    case validate_program(args) do
      {:ok, program} ->
        run_with_gate(program)

      {:error, message} ->
        Envelope.render_error(:args_error, message)
    end
  end

  defp run_with_gate(program) do
    cap = Limits.max_concurrent_calls()

    case ConcurrencyGate.try_acquire(cap) do
      :ok ->
        try do
          Sandbox.execute(program)
        after
          ConcurrencyGate.release()
        end

      :full ->
        Envelope.busy(cap)
    end
  end

  # § 9.2: missing → not a string → empty after trim → too large.
  defp validate_program(args) do
    case Map.fetch(args, "program") do
      :error ->
        {:error, "argument `program` is required"}

      {:ok, value} when not is_binary(value) ->
        {:error, "argument `program` must be a string, got #{type_label(value)}"}

      {:ok, value} ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" ->
            {:error, "argument `program` must be a non-empty string"}

          byte_size(value) > Limits.max_program_bytes() ->
            {:error,
             "argument `program` exceeds max_program_bytes (" <>
               Integer.to_string(byte_size(value)) <>
               " > " <>
               Integer.to_string(Limits.max_program_bytes()) <> ")"}

          true ->
            {:ok, value}
        end
    end
  end

  defp type_label(v) when is_map(v), do: "object"
  defp type_label(v) when is_list(v), do: "array"
  defp type_label(v) when is_integer(v), do: "integer"
  defp type_label(v) when is_float(v), do: "number"
  defp type_label(v) when is_boolean(v), do: "boolean"
  defp type_label(nil), do: "null"
  defp type_label(_), do: "unknown"

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
