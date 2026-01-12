defmodule PtcRunner.SubAgent.Compression.SingleUserCoalesced do
  @moduledoc """
  Default compression strategy that coalesces all context into a single USER message.

  This strategy transforms multi-turn execution history into a compact, LLM-optimized
  format. The output structure is:

      [
        %{role: :system, content: system_prompt},
        %{role: :user, content: mission + namespaces + history + errors + turns_left}
      ]

  ## Content Order in USER Message

  1. Mission text (always first, never removed)
  2. Namespace sections (tools, data/, user/)
  3. Expected output (return format from signature)
  4. Execution history (tool calls made, println output)
  5. Conditional error display (only if last turn failed)
  6. Turns indicator ("Turns left: N" or "FINAL TURN - ...")

  ## Error Handling

  Uses conditional collapsing based on recovery status:
  - If last turn failed: shows most recent error only
  - If last turn succeeded: collapses all errors (no error section)

  See [Message History Optimization](docs/specs/message-history-optimization-architecture.md).
  """
  @behaviour PtcRunner.SubAgent.Compression

  alias PtcRunner.SubAgent.Namespace
  alias PtcRunner.SubAgent.Namespace.ExecutionHistory
  alias PtcRunner.SubAgent.{Signature, SystemPrompt.Output}
  alias PtcRunner.Turn

  @impl true
  def name, do: "single-user-coalesced"

  @impl true
  @spec to_messages([Turn.t()], map(), keyword()) :: [PtcRunner.SubAgent.Compression.message()]
  def to_messages(turns, memory, opts) do
    system_msg = %{role: :system, content: opts[:system_prompt] || ""}
    user_msg = %{role: :user, content: build_user_content(turns, memory, opts)}

    [system_msg, user_msg]
  end

  defp build_user_content(turns, memory, opts) do
    prompt = opts[:prompt] || ""
    tools = opts[:tools] || %{}
    data = opts[:data] || %{}
    println_limit = opts[:println_limit] || 15
    tool_call_limit = opts[:tool_call_limit] || 20
    turns_left = opts[:turns_left] || 0
    signature = opts[:signature]
    field_descriptions = opts[:field_descriptions]

    # Split turns into successful and failed
    {successful_turns, failed_turns} = Enum.split_with(turns, & &1.success?)

    # Accumulate tool_calls and prints from all successful turns
    accumulated_tool_calls = Enum.flat_map(successful_turns, & &1.tool_calls)
    accumulated_prints = Enum.flat_map(successful_turns, & &1.prints)

    # Determine if any tool has println capability (used for output display)
    has_println = has_println_tool?(tools)

    # Build sections
    namespaces =
      Namespace.render(%{
        tools: tools,
        data: data,
        memory: memory,
        has_println: has_println
      })

    # Expected output section (from signature)
    expected_output = build_expected_output(signature, field_descriptions)

    tool_calls_section =
      ExecutionHistory.render_tool_calls(accumulated_tool_calls, tool_call_limit)

    output_section =
      ExecutionHistory.render_output(accumulated_prints, println_limit, has_println)

    # Conditional error display (only if last turn failed)
    error_section = build_error_section(turns, failed_turns)

    # Turns indicator
    turns_indicator = build_turns_indicator(turns_left)

    # Assemble sections with blank line separators
    [
      prompt,
      namespaces,
      expected_output,
      tool_calls_section,
      output_section,
      error_section,
      turns_indicator
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  # Check if any tool has println capability
  defp has_println_tool?(tools) do
    Enum.any?(tools, fn {_name, tool} ->
      tool.name == "println"
    end)
  end

  # Build expected output section from signature (compact format for compressed turns)
  defp build_expected_output(nil, _field_descriptions), do: nil

  defp build_expected_output(signature_str, field_descriptions) when is_binary(signature_str) do
    case Signature.parse(signature_str) do
      {:ok, parsed_sig} -> build_expected_output(parsed_sig, field_descriptions)
      {:error, _} -> nil
    end
  end

  defp build_expected_output({:signature, _, _} = signature, field_descriptions) do
    output = Output.generate(signature, field_descriptions)
    # Trim trailing newlines for cleaner joining
    String.trim_trailing(output)
  end

  defp build_expected_output(_, _), do: nil

  # Build error section based on conditional collapsing rules:
  # - If last turn failed: show most recent error only
  # - If recovered (last turn succeeded): collapse all errors (return nil)
  defp build_error_section([], _failed_turns), do: nil

  defp build_error_section(turns, _failed_turns) do
    last_turn = List.last(turns)

    if last_turn.success? do
      # Recovered - collapse all errors
      nil
    else
      # Last turn failed - show most recent error
      format_error(last_turn)
    end
  end

  defp format_error(%Turn{program: program, result: error}) do
    program_display = program || "(unknown program)"
    error_message = extract_error_message(error)

    """
    ---
    Your previous attempt:
    ```clojure
    #{program_display}
    ```

    Error: #{error_message}
    ---\
    """
  end

  defp extract_error_message(%{message: message}), do: message
  defp extract_error_message(%{reason: reason}), do: to_string(reason)
  defp extract_error_message(error) when is_binary(error), do: error
  defp extract_error_message(error), do: inspect(error)

  defp build_turns_indicator(0) do
    "FINAL TURN - you must call (return result) or (fail reason) now."
  end

  defp build_turns_indicator(n) when is_integer(n) and n > 0 do
    "Turns left: #{n}"
  end
end
