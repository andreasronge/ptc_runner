defmodule RlmRecursive.Progress do
  @moduledoc """
  Simple progress indicator using telemetry events.

  Prints dots and turn info as the agent executes.

  ## Usage

      RlmRecursive.Progress.attach()
      # ... run benchmark ...
      RlmRecursive.Progress.detach()

  Or use the with_progress/1 helper:

      RlmRecursive.Progress.with_progress(fn ->
        RlmRecursive.run(benchmark: :semantic_pairs, profiles: 40)
      end)
  """

  @handler_id "rlm-recursive-progress"

  @doc """
  Attach progress handlers to telemetry events.
  """
  def attach do
    :telemetry.attach_many(
      @handler_id,
      [
        [:ptc_runner, :sub_agent, :turn, :stop],
        [:ptc_runner, :sub_agent, :run, :start],
        [:ptc_runner, :sub_agent, :run, :stop],
        [:ptc_runner, :sub_agent, :tool, :start],
        [:ptc_runner, :sub_agent, :tool, :stop]
      ],
      &handle_event/4,
      %{start_time: System.monotonic_time(:millisecond)}
    )
  end

  @doc """
  Detach progress handlers.
  """
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc """
  Run a function with progress reporting enabled.
  """
  def with_progress(fun) do
    attach()

    try do
      fun.()
    after
      detach()
    end
  end

  # Handle turn completion - main progress indicator
  defp handle_event([:ptc_runner, :sub_agent, :turn, :stop], measurements, metadata, _config) do
    turn = metadata[:turn] || "?"
    tokens = measurements[:tokens] || 0
    duration_ms = div(measurements[:duration] || 0, 1_000_000)
    type = metadata[:type] || :normal
    depth = get_depth(metadata)

    # Indent based on depth
    indent = String.duplicate("  ", depth)

    # Show turn info
    status =
      case metadata[:result_preview] do
        nil -> "⏳"
        "nil" -> "·"
        result when is_binary(result) and byte_size(result) > 0 -> "✓"
        _ -> "·"
      end

    type_str = if type == :normal, do: "", else: " [#{type}]"

    IO.write("#{indent}#{status} Turn #{turn}#{type_str}: #{tokens} tokens, #{duration_ms}ms\n")
  end

  # Handle recursive tool calls
  defp handle_event([:ptc_runner, :sub_agent, :tool, :start], _measurements, metadata, _config) do
    tool_name = metadata[:tool_name]
    depth = get_depth(metadata)
    indent = String.duplicate("  ", depth)

    IO.write("#{indent}↳ Calling #{tool_name}...\n")
  end

  defp handle_event([:ptc_runner, :sub_agent, :tool, :stop], measurements, metadata, _config) do
    tool_name = metadata[:tool_name]
    duration_ms = div(measurements[:duration] || 0, 1_000_000)
    depth = get_depth(metadata)
    indent = String.duplicate("  ", depth)

    IO.write("#{indent}↲ #{tool_name} completed (#{duration_ms}ms)\n")
  end

  # Handle run start/stop for top-level progress
  defp handle_event([:ptc_runner, :sub_agent, :run, :start], _measurements, metadata, _config) do
    depth = get_depth(metadata)

    if depth == 0 do
      IO.write("\n🚀 Starting agent execution...\n\n")
    end
  end

  defp handle_event([:ptc_runner, :sub_agent, :run, :stop], measurements, metadata, _config) do
    depth = get_depth(metadata)
    duration_ms = div(measurements[:duration] || 0, 1_000_000)
    status = metadata[:status]

    if depth == 0 do
      status_emoji = if status == :ok, do: "✅", else: "❌"
      IO.write("\n#{status_emoji} Agent completed in #{div(duration_ms, 1000)}s\n")
    end
  end

  # Extract depth from metadata (nesting_depth or from span context)
  defp get_depth(metadata) do
    case metadata[:nesting_depth] do
      depth when is_integer(depth) ->
        depth

      nil ->
        if metadata[:parent_span_id] == nil, do: 0, else: 0
    end
  end
end
