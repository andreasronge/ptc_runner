defmodule PtcRunner.PlanTracer do
  @moduledoc """
  Real-time terminal visualization for PlanExecutor events.

  PlanTracer formats plan execution events into a hierarchical tree view with
  ANSI colors, providing immediate feedback during development and debugging.

  ## Quick Usage

  For simple logging without state tracking:

      {:ok, metadata} = PlanExecutor.execute(plan, mission,
        llm: my_llm,
        on_event: &PlanTracer.log_event/1
      )

  ## Stateful Tree View

  For proper hierarchical output with indentation:

      {:ok, tracer} = PlanTracer.start()

      {:ok, metadata} = PlanExecutor.execute(plan, mission,
        llm: my_llm,
        on_event: &PlanTracer.handle_event(tracer, &1)
      )

      PlanTracer.stop(tracer)

  ## Example Output

      Mission: Research stock prices
        [START] fetch_symbols
        [✓] fetch_symbols (150ms)
        [START] fetch_prices
        [!] fetch_prices - Verification failed: "Count < 5"
      REPLAN #1 (fetch_prices: "Count < 5")
        Repair plan: 2 tasks
        [-] fetch_symbols (Skipped)
        [START] fetch_prices
        [✓] fetch_prices (400ms)
      Execution finished: ok (1250ms)

  ## ANSI Colors

  - Green (✓): Successful tasks
  - Yellow (!): Verification failures, replans
  - Red (✗): Task failures
  - Cyan (-): Skipped tasks
  - Bold: Mission and replan headers

  See the [Observability Guide](subagent-observability.md) for turn history, telemetry events,
  and how PlanTracer relates to `PtcRunner.Tracer` and `PtcRunner.TraceLog`.
  """

  use Agent

  require Logger

  # ANSI color codes
  @green "\e[32m"
  @yellow "\e[33m"
  @red "\e[31m"
  @cyan "\e[36m"
  @bold "\e[1m"
  @reset "\e[0m"

  @type state :: %{
          mission: String.t() | nil,
          indent: non_neg_integer(),
          replan_count: non_neg_integer(),
          output: :logger | :io
        }

  # ============================================================================
  # Stateless API (simple logging)
  # ============================================================================

  @doc """
  Simple stateless event logger.

  Formats each event with colors and logs via Logger.info.
  No state tracking - suitable for quick debugging.

  ## Example

      PlanExecutor.execute(plan, mission,
        llm: my_llm,
        on_event: &PlanTracer.log_event/1
      )
  """
  @spec log_event(PtcRunner.PlanExecutor.event()) :: :ok
  def log_event(event) do
    message = format_event_simple(event)
    Logger.info(message)
    :ok
  end

  # ============================================================================
  # Stateful API (hierarchical tree view)
  # ============================================================================

  @doc """
  Starts a stateful tracer for hierarchical output.

  ## Options

  - `:output` - Where to send output: `:logger` (default) or `:io`

  ## Example

      {:ok, tracer} = PlanTracer.start(output: :io)
  """
  @spec start(keyword()) :: {:ok, pid()}
  def start(opts \\ []) do
    output = Keyword.get(opts, :output, :logger)

    initial_state = %{
      mission: nil,
      indent: 0,
      replan_count: 0,
      output: output
    }

    Agent.start_link(fn -> initial_state end)
  end

  @doc """
  Stops the tracer.
  """
  @spec stop(pid()) :: :ok
  def stop(tracer) do
    Agent.stop(tracer)
  end

  @doc """
  Handles an event with state tracking.

  Returns a function suitable for use as `on_event` callback.

  ## Example

      on_event = fn event -> PlanTracer.handle_event(tracer, event) end
      PlanExecutor.execute(plan, mission, llm: llm, on_event: on_event)
  """
  @spec handle_event(pid(), PtcRunner.PlanExecutor.event()) :: :ok
  def handle_event(tracer, event) do
    Agent.update(tracer, fn state ->
      {message, new_state} = format_event_stateful(event, state)
      output_message(new_state.output, message)
      new_state
    end)
  end

  @doc """
  Creates an event handler function bound to a tracer.

  ## Example

      {:ok, tracer} = PlanTracer.start()
      handler = PlanTracer.handler(tracer)
      PlanExecutor.execute(plan, mission, llm: llm, on_event: handler)
  """
  @spec handler(pid()) :: (PtcRunner.PlanExecutor.event() -> :ok)
  def handler(tracer) do
    fn event -> handle_event(tracer, event) end
  end

  # ============================================================================
  # Public Formatting (for testing)
  # ============================================================================

  @doc """
  Formats an event into a displayable string.

  This is the core formatting function used by both `log_event/1` and
  the stateful tracer. Exposed for testing purposes.
  """
  @spec format_event(PtcRunner.PlanExecutor.event()) :: String.t()
  def format_event(event), do: format_event_simple(event)

  # ============================================================================
  # Stateless Formatting
  # ============================================================================

  # Planning events (from run/2)
  defp format_event_simple({:planning_started, %{mission: mission}}) do
    "#{@cyan}#{@bold}Planning:#{@reset} #{mission}"
  end

  defp format_event_simple({:planning_finished, %{task_count: count}}) do
    "#{@green}[✓]#{@reset} Plan generated (#{count} tasks)"
  end

  defp format_event_simple({:planning_failed, %{reason: reason}}) do
    "#{@red}[✗]#{@reset} Planning failed: #{inspect(reason)}"
  end

  defp format_event_simple({:planning_retry, %{validation_errors: count}}) do
    "#{@yellow}[!]#{@reset} Plan invalid, retrying with #{count} validation error(s)..."
  end

  # Execution events
  defp format_event_simple({:execution_started, %{mission: mission, task_count: count}}) do
    "#{@bold}Mission: #{mission}#{@reset} (#{count} tasks)"
  end

  defp format_event_simple({:execution_finished, %{status: status, duration_ms: ms}}) do
    status_str = format_status(status)
    "#{@bold}Execution finished:#{@reset} #{status_str} (#{ms}ms)"
  end

  defp format_event_simple({:task_started, %{task_id: id, attempt: attempt}}) do
    attempt_str = if attempt > 1, do: " (attempt #{attempt})", else: ""
    "[START] #{id}#{attempt_str}"
  end

  defp format_event_simple({:task_succeeded, %{task_id: id, duration_ms: ms}}) do
    "#{@green}[✓]#{@reset} #{id} (#{ms}ms)"
  end

  defp format_event_simple({:task_failed, %{task_id: id, reason: reason}}) do
    "#{@red}[✗]#{@reset} #{id} - #{inspect(reason)}"
  end

  defp format_event_simple({:task_skipped, %{task_id: id, reason: reason}}) do
    "#{@cyan}[-]#{@reset} #{id} (Skipped: #{reason})"
  end

  defp format_event_simple({:verification_failed, %{task_id: id, diagnosis: diagnosis}}) do
    "#{@yellow}[!]#{@reset} #{id} - Verification failed: \"#{diagnosis}\""
  end

  defp format_event_simple(
         {:replan_started, %{task_id: id, diagnosis: diagnosis, total_replans: n}}
       ) do
    "#{@yellow}#{@bold}REPLAN ##{n}#{@reset}#{@yellow} (#{id}: \"#{diagnosis}\")#{@reset}"
  end

  defp format_event_simple({:replan_finished, %{new_tasks: count}}) do
    "  Repair plan: #{count} task(s)"
  end

  defp format_event_simple({:quality_gate_started, %{task_id: id}}) do
    "[GATE] #{id} - Checking data sufficiency"
  end

  defp format_event_simple({:quality_gate_passed, %{task_id: id}}) do
    "#{@green}[GATE ✓]#{@reset} #{id}"
  end

  defp format_event_simple({:quality_gate_failed, %{task_id: id, missing: missing}}) do
    missing_str = Enum.join(missing, ", ")
    "#{@yellow}[GATE !]#{@reset} #{id} - Missing: #{missing_str}"
  end

  defp format_event_simple({:quality_gate_error, %{task_id: id, reason: reason}}) do
    "#{@red}[GATE ✗]#{@reset} #{id} - #{inspect(reason)}"
  end

  defp format_event_simple(event) do
    "Unknown event: #{inspect(event)}"
  end

  # ============================================================================
  # Stateful Formatting
  # ============================================================================

  # Planning events (from run/2)
  defp format_event_stateful({:planning_started, %{mission: mission}}, state) do
    message = "#{@cyan}#{@bold}Planning:#{@reset} #{mission}"
    {message, %{state | mission: mission}}
  end

  defp format_event_stateful({:planning_finished, %{task_count: count}}, state) do
    message = "#{indent(state)}#{@green}[✓]#{@reset} Plan generated (#{count} tasks)"
    {message, state}
  end

  defp format_event_stateful({:planning_failed, %{reason: reason}}, state) do
    message = "#{indent(state)}#{@red}[✗]#{@reset} Planning failed: #{inspect(reason)}"
    {message, state}
  end

  defp format_event_stateful({:planning_retry, %{validation_errors: count}}, state) do
    message =
      "#{indent(state)}#{@yellow}[!]#{@reset} Plan invalid, retrying with #{count} validation error(s)..."

    {message, state}
  end

  # Execution events
  defp format_event_stateful({:execution_started, %{mission: mission, task_count: count}}, state) do
    message = "#{@bold}Mission: #{mission}#{@reset} (#{count} tasks)"
    {message, %{state | mission: mission, indent: 1}}
  end

  defp format_event_stateful({:execution_finished, %{status: status, duration_ms: ms}}, state) do
    status_str = format_status(status)
    message = "#{@bold}Execution finished:#{@reset} #{status_str} (#{ms}ms)"
    {message, %{state | indent: 0}}
  end

  defp format_event_stateful({:task_started, %{task_id: id, attempt: attempt}}, state) do
    attempt_str = if attempt > 1, do: " (attempt #{attempt})", else: ""
    message = "#{indent(state)}[START] #{id}#{attempt_str}"
    {message, state}
  end

  defp format_event_stateful({:task_succeeded, %{task_id: id, duration_ms: ms}}, state) do
    message = "#{indent(state)}#{@green}[✓]#{@reset} #{id} (#{ms}ms)"
    {message, state}
  end

  defp format_event_stateful({:task_failed, %{task_id: id, reason: reason}}, state) do
    message = "#{indent(state)}#{@red}[✗]#{@reset} #{id} - #{inspect(reason)}"
    {message, state}
  end

  defp format_event_stateful({:task_skipped, %{task_id: id, reason: reason}}, state) do
    message = "#{indent(state)}#{@cyan}[-]#{@reset} #{id} (Skipped: #{reason})"
    {message, state}
  end

  defp format_event_stateful({:verification_failed, %{task_id: id, diagnosis: diagnosis}}, state) do
    message =
      "#{indent(state)}#{@yellow}[!]#{@reset} #{id} - Verification failed: \"#{diagnosis}\""

    {message, state}
  end

  defp format_event_stateful(
         {:replan_started, %{task_id: id, diagnosis: diagnosis, total_replans: n}},
         state
       ) do
    message =
      "#{@yellow}#{@bold}REPLAN ##{n}#{@reset}#{@yellow} (#{id}: \"#{diagnosis}\")#{@reset}"

    {message, %{state | replan_count: n, indent: 1}}
  end

  defp format_event_stateful({:replan_finished, %{new_tasks: count}}, state) do
    message = "#{indent(state)}Repair plan: #{count} task(s)"
    {message, state}
  end

  defp format_event_stateful({:quality_gate_started, %{task_id: id}}, state) do
    message = "#{indent(state)}[GATE] #{id} - Checking data sufficiency"
    {message, state}
  end

  defp format_event_stateful({:quality_gate_passed, %{task_id: id}}, state) do
    message = "#{indent(state)}#{@green}[GATE ✓]#{@reset} #{id}"
    {message, state}
  end

  defp format_event_stateful({:quality_gate_failed, %{task_id: id, missing: missing}}, state) do
    missing_str = Enum.join(missing, ", ")
    message = "#{indent(state)}#{@yellow}[GATE !]#{@reset} #{id} - Missing: #{missing_str}"
    {message, state}
  end

  defp format_event_stateful({:quality_gate_error, %{task_id: id, reason: reason}}, state) do
    message = "#{indent(state)}#{@red}[GATE ✗]#{@reset} #{id} - #{inspect(reason)}"
    {message, state}
  end

  defp format_event_stateful(event, state) do
    message = "#{indent(state)}Unknown event: #{inspect(event)}"
    {message, state}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp indent(%{indent: level}) do
    String.duplicate("  ", level)
  end

  defp format_status(:ok), do: "#{@green}ok#{@reset}"
  defp format_status(:error), do: "#{@red}error#{@reset}"
  defp format_status(:waiting), do: "#{@yellow}waiting#{@reset}"
  defp format_status(other), do: "#{other}"

  defp output_message(:logger, message) do
    # Strip ANSI codes for logger (they don't render in most log outputs)
    clean_message = strip_ansi(message)
    Logger.info(clean_message)
  end

  defp output_message(:io, message) do
    IO.puts(message)
  end

  defp strip_ansi(string) do
    String.replace(string, ~r/\e\[[0-9;]*m/, "")
  end
end
