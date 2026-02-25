defmodule Alma.TaskAgent do
  @moduledoc """
  Runs a single task using either tool-calling (SubAgent) or plain-text mode.

  The mode is determined by the environment's `task_mode/0` callback:
  - `:tools` (default) — SubAgent with tool calling
  - `:text` — ReAct-style text loop, no tool schemas

  In text mode the LLM receives observations as user messages and responds
  with an action string. This saves tokens (no tool schemas per turn) and
  matches the original ALMA paper's ALFWorld approach.
  """

  alias PtcRunner.SubAgent

  @doc """
  Runs a task, returning a result map with success status and trajectory.

  The `knowledge` parameter is a text string from the recall function (or "").

  ## Options

    * `:llm` - LLM callback (required)
    * `:environment` - environment module implementing `Alma.Environment` (required)
  """
  def run(task_config, knowledge, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    env_module = Keyword.fetch!(opts, :environment)

    Code.ensure_loaded(env_module)

    mode =
      if function_exported?(env_module, :task_mode, 0),
        do: env_module.task_mode(),
        else: :tools

    case mode do
      :text -> run_text_mode(task_config, knowledge, env_module, llm)
      :tools -> run_tool_mode(task_config, knowledge, env_module, llm)
    end
  end

  # ============================================================
  # Text Mode — ReAct-style plain text loop
  # ============================================================

  defp run_text_mode(task_config, knowledge, env_module, llm) do
    state = env_module.reset(task_config)
    goal_text = env_module.format_goal(state[:goal] || task_config.goal)
    max_turns = get_max_turns(env_module)

    system =
      env_module.task_prompt()
      |> String.replace("{{goal}}", goal_text)
      |> String.trim()

    system =
      if knowledge != "" and knowledge != nil do
        system <> "\n\nAdvice from past episodes:\n#{knowledge}"
      else
        system
      end

    # Initial observation
    obs_text = env_module.observe(state) |> env_module.format_step_result()
    messages = [%{role: :user, content: obs_text}]

    text_loop(state, messages, system, env_module, llm, max_turns, 0, [])
    |> Map.put(:goal, goal_text)
  end

  defp text_loop(state, _messages, _system, env_module, _llm, max_turns, turn, obs_log)
       when turn >= max_turns do
    %{
      success?: env_module.success?(state),
      actions: Enum.map(obs_log, & &1.action),
      steps: state.steps,
      observation_log: obs_log
    }
  end

  defp text_loop(state, _messages, _system, env_module, _llm, _max_turns, _turn, obs_log)
       when state.done == true do
    %{
      success?: env_module.success?(state),
      actions: Enum.map(obs_log, & &1.action),
      steps: state.steps,
      observation_log: obs_log
    }
  end

  defp text_loop(state, messages, system, env_module, llm, max_turns, turn, obs_log) do
    case llm.(%{system: system, messages: messages}) do
      {:ok, %{content: response}} ->
        action = env_module.parse_action(response, state)
        {result, new_state} = env_module.step(state, action)
        obs_text = env_module.format_step_result(result)

        new_messages =
          messages ++
            [
              %{role: :assistant, content: response},
              %{role: :user, content: obs_text}
            ]

        action_str =
          case action do
            {:invalid, attempted} -> "(invalid) #{attempted}"
            a when is_binary(a) -> a
          end

        new_obs_log = obs_log ++ [%{action: action_str, result: result}]

        text_loop(
          new_state,
          new_messages,
          system,
          env_module,
          llm,
          max_turns,
          turn + 1,
          new_obs_log
        )

      {:error, reason} ->
        %{
          success?: false,
          actions: [],
          steps: state.steps,
          observation_log: obs_log,
          error: reason
        }
    end
  end

  # ============================================================
  # Tool Mode — SubAgent with tool calling
  # ============================================================

  defp run_tool_mode(task_config, knowledge, env_module, llm) do
    state = env_module.reset(task_config)
    {:ok, agent_pid} = Agent.start_link(fn -> state end)

    try do
      tools = env_module.task_tools(agent_pid, knowledge)
      goal_text = env_module.format_goal(state[:goal] || task_config.goal)
      max_turns = get_max_turns(env_module)

      agent =
        SubAgent.new(
          name: "task_agent",
          prompt: env_module.task_prompt(),
          output: :text,
          tools: tools,
          max_turns: max_turns,
          max_tool_calls: max_turns,
          format_options: [result_max_chars: 4000],
          timeout: 5000,
          max_heap: 6_250_000
        )

      case SubAgent.run(agent,
             llm: llm,
             context: %{"goal" => goal_text}
           ) do
        {:ok, step} ->
          final_state = Agent.get(agent_pid, & &1)

          %{
            success?: env_module.success?(final_state),
            actions: extract_actions(step),
            steps: final_state.steps,
            observation_log: extract_observations(step),
            goal: goal_text
          }

        {:error, reason} ->
          %{success?: false, actions: [], steps: 0, observation_log: [], error: reason}
      end
    after
      Agent.stop(agent_pid)
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp get_max_turns(env_module) do
    if function_exported?(env_module, :max_task_turns, 0),
      do: env_module.max_task_turns(),
      else: 10
  end

  defp extract_actions(step) do
    all_tool_calls =
      (step.turns || [])
      |> Enum.flat_map(fn turn -> turn.tool_calls || [] end)

    tool_calls = if all_tool_calls == [], do: step.tool_calls || [], else: all_tool_calls
    Enum.map(tool_calls, fn tc -> tc.name end)
  end

  defp extract_observations(step) do
    all_tool_calls =
      (step.turns || [])
      |> Enum.flat_map(fn turn -> turn.tool_calls || [] end)

    tool_calls = if all_tool_calls == [], do: step.tool_calls || [], else: all_tool_calls
    Enum.map(tool_calls, fn tc -> %{action: tc.name, result: tc.result} end)
  end
end
