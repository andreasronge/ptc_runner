defmodule PtcRunnerMcp.AgenticConfig do
  @moduledoc """
  Boot-time configuration for experimental agentic aggregator mode.

  Agentic mode is opt-in. It exposes `ptc_task` only when ordinary
  aggregator mode is active, and it never changes `ptc_lisp_execute`.
  """

  @defaults %{
    enabled: false,
    model: "gemini-flash-lite",
    task_timeout_ms: 45_000,
    planner_timeout_ms: 15_000,
    max_output_tokens: 1_200,
    max_result_bytes: 4_096,
    include_program: true,
    trace_prompts: false
  }

  @type t :: %{
          enabled: boolean(),
          model: String.t(),
          task_timeout_ms: pos_integer(),
          planner_timeout_ms: pos_integer(),
          max_output_tokens: pos_integer(),
          max_result_bytes: pos_integer(),
          include_program: boolean(),
          trace_prompts: boolean()
        }

  @spec defaults() :: t()
  def defaults, do: @defaults

  @spec set(map()) :: :ok
  def set(overrides) when is_map(overrides) do
    merged = Map.merge(defaults(), Map.take(overrides, Map.keys(defaults())))
    :persistent_term.put({__MODULE__, :config}, merged)
    :ok
  end

  @spec get() :: t()
  def get do
    :persistent_term.get({__MODULE__, :config}, defaults())
  end

  @spec enabled?() :: boolean()
  def enabled?, do: get().enabled == true
end
