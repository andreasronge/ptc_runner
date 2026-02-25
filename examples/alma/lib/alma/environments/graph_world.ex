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

  @impl true
  def task_prompt do
    """
    Navigate connected rooms to complete the goal: {{goal}}.
    Call recall first for advice from past episodes, then use the tools
    efficiently — combine multiple tool calls per turn when possible
    (e.g. pick_up then move_to, or look then move_to).
    """
  end

  @impl true
  def task_tools(agent_pid, knowledge) do
    %{
      "look" => {
        fn _args ->
          Agent.get(agent_pid, &__MODULE__.observe/1)
        end,
        signature: "() -> :any",
        description:
          "Look around the current room. Returns location, exits, objects, inventory, and goal."
      },
      "move_to" => {
        fn %{"room" => room} ->
          Agent.get_and_update(agent_pid, fn state ->
            __MODULE__.step(state, {:move_to, room})
          end)
        end,
        signature: "(room :string) -> :any", description: "Move to an adjacent room."
      },
      "pick_up" => {
        fn %{"object" => object} ->
          Agent.get_and_update(agent_pid, fn state ->
            __MODULE__.step(state, {:pick_up, object})
          end)
        end,
        signature: "(object :string) -> :any",
        description: "Pick up an object in the current room."
      },
      "put_down" => {
        fn %{"object" => object} ->
          Agent.get_and_update(agent_pid, fn state ->
            __MODULE__.step(state, {:put_down, object})
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

  @impl true
  def generate_tasks(count, env_config) do
    Alma.Environments.GraphWorld.Generator.generate_batch(count, env_config)
  end

  @impl true
  def generate_family_tasks(count, env_config) do
    Alma.Environments.GraphWorld.Generator.generate_family_batch(count, env_config)
  end

  @impl true
  def setup(opts) do
    %{
      rooms: Keyword.get(opts, :rooms, 5),
      objects: 3,
      connectivity: 0.3,
      seed: Keyword.get(opts, :seed, 42),
      family: Keyword.get(opts, :family, Keyword.get(opts, :seed, 42))
    }
  end

  @impl true
  def seed_design_source do
    ~S"""
    (do
      (defn mem-update []
        ;; Always extract spatial and object data — failed episodes reveal the map too
        (doseq [obs data/observation_log]
          (let [result (:result obs)
                loc (:location result)
                objects (:objects result)
                exits (:exits result)]
            (when loc
              ;; Build graph from observed room connections
              (when (seq exits)
                (tool/graph-update {"edges" (map (fn [exit] [loc exit]) exits)}))
              ;; Store object sightings in a dedicated collection
              (when (seq objects)
                (doseq [obj objects]
                  (tool/store-obs {"text" (str obj " seen in " loc)
                                   "metadata" {"item" obj "room" loc}
                                   "collection" "objects"})))))))

      (defn recall []
        (let [goal (:goal data/task)
              target (if (map? goal) (:object goal) (str goal))
              dest (if (map? goal) (:destination goal) nil)
              ;; Look up where the target was seen
              hits (tool/find-similar {"query" (str target) "k" 3 "collection" "objects"})
              item-loc (when (seq hits) (get (first hits) "metadata"))
              item-room (when item-loc (get item-loc "room"))
              ;; Compute path to destination if we know it
              start (:agent_location data/task)
              path-to-dest (when (and start dest) (tool/graph-path {"from" start "to" dest}))]
          (str
            (if item-room (str target " was seen in " item-room ". ") "")
            (if (and path-to-dest (> (count path-to-dest) 1))
              (str "Path to " dest ": " (clojure.string/join " -> " path-to-dest))
              (if dest (str "Deliver to " dest ".") "")))))

      (return {"name" "spatial_baseline"
               "description" "Builds graph from exits, stores objects by collection, provides pathfinding in recall"}))
    """
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
