defmodule Alma.Environments.GraphWorld do
  @moduledoc """
  A graph-based navigation environment where an agent moves between rooms,
  picks up objects, and delivers them to goal destinations.
  """

  @behaviour Alma.Environment

  @impl true
  def context_schema do
    %{
      "mem_update" => %{
        "data/task" =>
          "map with atom keys — :rooms (map of name => %{adjacent: [...], objects: [...]}), :agent_location (string), :goal (%{object: string, destination: string})",
        "data/actions" =>
          "list of action name strings — NOT maps, just strings like the action name and arguments",
        "data/success" => "boolean — whether the task goal was achieved",
        "data/observation_log" =>
          "list of maps with atom keys — :action (string) and :result (map with atom keys :location, :exits, :objects, :inventory, :goal). Use this for detailed per-step data, not data/actions."
      },
      "recall" => %{
        "data/task" =>
          "map with atom keys — :rooms, :agent_location, :goal (same structure as mem_update)",
        "data/current_observation" =>
          "map with atom keys — :location (string), :exits (list of strings), :objects (list of strings), :inventory (list of strings), :goal (string)"
      }
    }
  end

  @impl true
  def reset(config) do
    %{
      rooms: config.rooms,
      agent_location: config.agent_location,
      inventory: [],
      goal: config.goal,
      steps: 0,
      max_steps: Map.get(config, :max_steps, 20)
    }
  end

  @impl true
  def step(state, action) do
    state = %{state | steps: state.steps + 1}

    if state.steps > state.max_steps do
      {%{ok: false, message: "Max steps exceeded"}, state}
    else
      execute_action(state, action)
    end
  end

  @impl true
  def observe(state) do
    room = Map.fetch!(state.rooms, state.agent_location)

    %{
      location: state.agent_location,
      exits: room.adjacent,
      objects: room.objects,
      inventory: state.inventory,
      goal: "Bring #{state.goal.object} to #{state.goal.destination}"
    }
  end

  @impl true
  def success?(state) do
    room = Map.fetch!(state.rooms, state.goal.destination)
    state.goal.object in room.objects
  end

  @impl true
  def summarize_observation(%{action: "look", result: result}, goal) when is_map(result) do
    location = Map.get(result, :location) || "?"
    objects = Map.get(result, :objects) || []
    goal_object = Map.get(goal, :object)

    discovery =
      if goal_object && goal_object in objects,
        do: "found #{goal_object}!",
        else: nil

    %{action_summary: "look(#{location})", state_identifier: location, discovery: discovery}
  end

  def summarize_observation(%{action: "move_to", result: result}, _goal) when is_map(result) do
    message = Map.get(result, :message) || ""

    room =
      case Regex.run(~r/Moved to (\S+)/, message) do
        [_, room] -> room
        _ -> "?"
      end

    %{action_summary: "move_to(#{room})", state_identifier: nil, discovery: nil}
  end

  def summarize_observation(%{action: "pick_up", result: result}, _goal) when is_map(result) do
    message = Map.get(result, :message) || ""

    object =
      if String.starts_with?(message, "Picked up "),
        do: String.replace_prefix(message, "Picked up ", ""),
        else: "?"

    %{action_summary: "pick_up(#{object})", state_identifier: nil, discovery: nil}
  end

  def summarize_observation(%{action: "put_down", result: result}, _goal) when is_map(result) do
    message = Map.get(result, :message) || ""

    object =
      if String.starts_with?(message, "Put down "),
        do: String.replace_prefix(message, "Put down ", ""),
        else: "?"

    %{action_summary: "put_down(#{object})", state_identifier: nil, discovery: nil}
  end

  def summarize_observation(%{action: "recall"}, _goal) do
    %{action_summary: "recall", state_identifier: nil, discovery: nil}
  end

  def summarize_observation(%{action: action}, _goal) do
    %{action_summary: action, state_identifier: nil, discovery: nil}
  end

  @impl true
  def format_goal(goal) do
    "Place #{goal.object} in #{goal.destination}"
  end

  defp execute_action(state, {:move_to, room}) do
    current_room = Map.fetch!(state.rooms, state.agent_location)

    if room in current_room.adjacent do
      {%{ok: true, message: "Moved to #{room}"}, %{state | agent_location: room}}
    else
      {%{ok: false, message: "Cannot move to #{room}: not adjacent"}, state}
    end
  end

  defp execute_action(state, {:pick_up, object}) do
    room = Map.fetch!(state.rooms, state.agent_location)

    if object in room.objects do
      updated_rooms =
        Map.update!(state.rooms, state.agent_location, fn r ->
          %{r | objects: List.delete(r.objects, object)}
        end)

      {%{ok: true, message: "Picked up #{object}"},
       %{state | rooms: updated_rooms, inventory: [object | state.inventory]}}
    else
      {%{ok: false, message: "#{object} is not here"}, state}
    end
  end

  defp execute_action(state, {:put_down, object}) do
    if object in state.inventory do
      updated_rooms =
        Map.update!(state.rooms, state.agent_location, fn r ->
          %{r | objects: [object | r.objects]}
        end)

      {%{ok: true, message: "Put down #{object}"},
       %{state | rooms: updated_rooms, inventory: List.delete(state.inventory, object)}}
    else
      {%{ok: false, message: "#{object} is not in inventory"}, state}
    end
  end
end
