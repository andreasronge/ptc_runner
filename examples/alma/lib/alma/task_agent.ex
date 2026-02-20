defmodule Alma.TaskAgent do
  @moduledoc """
  Runs a single navigation task using SubAgent with GraphWorld tools.

  Tools are closures over an Agent process holding the mutable GraphWorld state.
  A `recall` tool provides knowledge from past episodes.
  """

  alias PtcRunner.SubAgent
  alias Alma.Environments.GraphWorld

  @doc """
  Runs a navigation task, returning a result map with success status and trajectory.

  The `knowledge` parameter is a text string from the recall function (or "").
  """
  def run(task_config, knowledge, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)

    state = GraphWorld.reset(task_config)
    {:ok, agent_pid} = Agent.start_link(fn -> state end)

    try do
      tools = make_tools(agent_pid, knowledge)

      agent =
        SubAgent.new(
          name: "task_agent",
          prompt: task_agent_prompt(),
          signature: "(goal :string) -> :any",
          tools: tools,
          max_turns: 10,
          max_tool_calls: 10,
          timeout: 5000,
          max_heap: 6_250_000,
          format_options: [feedback_max_chars: 2048]
        )

      goal_text = "Place #{task_config.goal.object} in #{task_config.goal.destination}"

      case SubAgent.run(agent,
             llm: llm,
             context: %{"goal" => goal_text}
           ) do
        {:ok, step} ->
          final_state = Agent.get(agent_pid, & &1)

          %{
            success?: GraphWorld.success?(final_state),
            actions: extract_actions(step),
            steps: final_state.steps,
            observation_log: extract_observations(step)
          }

        {:error, reason} ->
          %{success?: false, actions: [], steps: 0, observation_log: [], error: reason}
      end
    after
      Agent.stop(agent_pid)
    end
  end

  defp make_tools(agent_pid, knowledge) do
    %{
      "look" => {
        fn _args ->
          Agent.get(agent_pid, &GraphWorld.observe/1)
        end,
        signature: "() -> :any",
        description:
          "Look around the current room. Returns location, exits, objects, inventory, and goal."
      },
      "move_to" => {
        fn %{"room" => room} ->
          Agent.get_and_update(agent_pid, fn state ->
            {result, new_state} = GraphWorld.step(state, {:move_to, room})
            {result, new_state}
          end)
        end,
        signature: "(room :string) -> :any", description: "Move to an adjacent room."
      },
      "pick_up" => {
        fn %{"object" => object} ->
          Agent.get_and_update(agent_pid, fn state ->
            {result, new_state} = GraphWorld.step(state, {:pick_up, object})
            {result, new_state}
          end)
        end,
        signature: "(object :string) -> :any",
        description: "Pick up an object in the current room."
      },
      "put_down" => {
        fn %{"object" => object} ->
          Agent.get_and_update(agent_pid, fn state ->
            {result, new_state} = GraphWorld.step(state, {:put_down, object})
            {result, new_state}
          end)
        end,
        signature: "(object :string) -> :any",
        description: "Put down an object from your inventory in the current room."
      },
      "recall" => {
        fn _args -> knowledge end,
        signature: "() -> :string",
        description: "Recall knowledge from past episodes. Returns advice text."
      }
    }
  end

  defp task_agent_prompt do
    """
    Navigate connected rooms to complete the goal. Call recall first for advice
    from past episodes, then act efficiently — combine multiple tool calls per
    turn when possible (e.g. pick_up then move_to, or look then move_to).
    """
  end

  defp extract_actions(step) do
    # Collect from all turns for multi-turn agents
    all_tool_calls =
      (step.turns || [])
      |> Enum.flat_map(fn turn -> turn.tool_calls || [] end)

    tool_calls = if all_tool_calls == [], do: step.tool_calls || [], else: all_tool_calls
    Enum.map(tool_calls, fn tc -> tc.name end)
  end

  defp extract_observations(step) do
    # Collect tool calls from ALL turns, not just the last one.
    # step.tool_calls only has the last turn's calls, but step.turns
    # contains the full multi-turn history.
    all_tool_calls =
      (step.turns || [])
      |> Enum.flat_map(fn turn -> turn.tool_calls || [] end)

    # Fall back to step.tool_calls if turns is empty (single-shot)
    tool_calls = if all_tool_calls == [], do: step.tool_calls || [], else: all_tool_calls

    Enum.map(tool_calls, fn tc -> %{action: tc.name, result: tc.result} end)
  end
end
