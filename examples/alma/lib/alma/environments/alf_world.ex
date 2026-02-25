defmodule Alma.Environments.ALFWorld do
  @moduledoc """
  ALFWorld text-based household environment for ALMA.

  Communicates with ALFWorld via a Python bridge process. The agent selects
  from admissible text commands to navigate and manipulate objects in a
  simulated household.

  Requires Python with `alfworld` installed. Start with:

      mix alma.run --env alfworld
  """

  @behaviour Alma.Environment

  alias Alma.Environments.ALFWorld.Port, as: AlfPort

  @impl true
  def context_schema do
    %{
      "mem_update" => %{
        "data/task" =>
          "map with atom keys — :goal (string), :game_file (string path). Access goal with (:goal data/task)",
        "data/actions" => "list of action strings taken during the episode",
        "data/success" => "boolean — whether the task goal was achieved",
        "data/observation_log" =>
          "list of maps with atom keys — :action (string command) and :result (map with :obs string, :admissible_commands list, :done boolean, :score float)"
      },
      "recall" => %{
        "data/task" =>
          "map with atom keys — :goal (string), :game_file (string path). Access goal with (:goal data/task)",
        "data/current_observation" =>
          "map with atom keys — :obs (string), :admissible_commands (list of strings), :goal (string)"
      }
    }
  end

  @impl true
  def reset(config) do
    port_pid = config[:port_pid] || raise "ALFWorld requires :port_pid in config"

    case AlfPort.command(port_pid, %{cmd: "reset", game_file: config[:game_file]}) do
      {:ok, %{"status" => "error", "error" => error}} ->
        raise "ALFWorld reset failed: #{error}"

      {:ok, response} ->
        %{
          port_pid: port_pid,
          obs: response["obs"],
          admissible_commands: response["admissible_commands"] || [],
          goal: extract_goal(response["obs"]) || response["goal"],
          done: response["done"] || false,
          score: response["score"] || 0,
          steps: 0,
          max_steps: Map.get(config, :max_steps, 30),
          game_file: config[:game_file]
        }

      {:error, reason} ->
        raise "ALFWorld reset failed: #{inspect(reason)}"
    end
  end

  @impl true
  def step(state, {:invalid, attempted}) do
    # Don't count invalid commands as steps — give the LLM another chance
    result = %{
      obs:
        "Invalid command: \"#{attempted}\". You must choose EXACTLY one command from the admissible list below.",
      admissible_commands: state.admissible_commands,
      done: false,
      score: state.score
    }

    {result, state}
  end

  def step(state, action) when is_binary(action) do
    state = %{state | steps: state.steps + 1}

    if state.steps > state.max_steps do
      {%{obs: "Max steps exceeded.", admissible_commands: [], done: true, score: state.score},
       %{state | done: true}}
    else
      case AlfPort.command(state.port_pid, %{cmd: "step", action: action}) do
        {:ok, %{"status" => "error", "error" => error}} ->
          {%{obs: "Error: #{error}", admissible_commands: [], done: true, score: 0},
           %{state | done: true}}

        {:ok, response} ->
          new_state = %{
            state
            | obs: response["obs"],
              admissible_commands: response["admissible_commands"] || [],
              done: response["done"] || false,
              score: response["score"] || 0
          }

          result = %{
            obs: new_state.obs,
            admissible_commands: new_state.admissible_commands,
            done: new_state.done,
            score: new_state.score
          }

          {result, new_state}

        {:error, reason} ->
          {%{obs: "Error: #{inspect(reason)}", admissible_commands: [], done: true, score: 0},
           %{state | done: true}}
      end
    end
  end

  @impl true
  def observe(state) do
    %{
      obs: state.obs,
      admissible_commands: state.admissible_commands,
      goal: state.goal
    }
  end

  @impl true
  def success?(state) do
    state.done && state.score > 0
  end

  @impl true
  def summarize_observation(%{action: action, result: result}, _goal) when is_map(result) do
    obs = Map.get(result, :obs, "")

    cond do
      String.starts_with?(action, "go to ") ->
        location = String.replace_prefix(action, "go to ", "")

        %{
          action_summary: "go_to(#{location})",
          state_identifier: location,
          discovery: nil
        }

      String.starts_with?(action, "take ") ->
        item = action |> String.replace_prefix("take ", "") |> String.split(" from ") |> hd()

        %{
          action_summary: "take(#{item})",
          state_identifier: nil,
          discovery: if(String.contains?(obs, "Nothing happens"), do: nil, else: "took #{item}")
        }

      String.starts_with?(action, "put ") ->
        parts = String.replace_prefix(action, "put ", "")

        %{
          action_summary: "put(#{parts})",
          state_identifier: nil,
          discovery: nil
        }

      String.starts_with?(action, "open ") ->
        target = String.replace_prefix(action, "open ", "")

        discovery =
          if String.contains?(obs, "Nothing happens"), do: nil, else: "opened #{target}"

        %{
          action_summary: "open(#{target})",
          state_identifier: nil,
          discovery: discovery
        }

      String.starts_with?(action, "close ") ->
        target = String.replace_prefix(action, "close ", "")
        %{action_summary: "close(#{target})", state_identifier: nil, discovery: nil}

      String.starts_with?(action, "use ") ->
        target = String.replace_prefix(action, "use ", "")
        %{action_summary: "use(#{target})", state_identifier: nil, discovery: nil}

      action in ["look", "inventory"] ->
        %{action_summary: action, state_identifier: nil, discovery: nil}

      action == "recall" ->
        %{action_summary: "recall", state_identifier: nil, discovery: nil}

      true ->
        %{action_summary: action, state_identifier: nil, discovery: nil}
    end
  end

  def summarize_observation(%{action: action}, _goal) do
    %{action_summary: action, state_identifier: nil, discovery: nil}
  end

  @impl true
  def format_goal(%{goal: goal}) when is_binary(goal), do: goal
  def format_goal(goal) when is_binary(goal), do: goal
  def format_goal(goal) when is_map(goal), do: Map.get(goal, :goal, inspect(goal))

  @impl true
  def task_mode, do: :text

  @impl true
  def task_prompt do
    """
    You are an agent in a household simulator. Each turn you receive your current
    observation and a list of admissible commands. Respond with EXACTLY ONE command
    from the list. Output ONLY the command text, nothing else.

    Goal: {{goal}}

    Action types:
    - go to [receptacle] — navigate to a location
    - take [object] from [receptacle] — pick up an object
    - put [object] in/on [receptacle] — place a held object
    - open [receptacle] — open a container/appliance
    - close [receptacle] — close a container/appliance
    - toggle [object/appliance] — turn on/off (e.g. desklamp, faucet)
    - clean [object] with [receptacle] — wash (e.g. sinkbasin)
    - heat [object] with [receptacle] — heat (e.g. microwave)
    - cool [object] with [receptacle] — cool (e.g. fridge)
    - examine [object/receptacle] — look closely
    - inventory — check what you're carrying
    - look — observe surroundings

    Strategy: Think about where the target object likely is, go there directly,
    and execute the required manipulation. Don't explore randomly.
    """
  end

  @impl true
  def format_step_result(result), do: format_result(result)

  @impl true
  def parse_action(response, state) do
    trimmed = String.trim(response)

    cond do
      trimmed in state.admissible_commands ->
        trimmed

      match = Enum.find(state.admissible_commands, fn cmd -> String.contains?(response, cmd) end) ->
        match

      true ->
        # Return a sentinel that step/2 won't send to the bridge.
        # format_step_result/1 will show the error + admissible commands.
        {:invalid, trimmed}
    end
  end

  @doc false
  def format_result(%{obs: obs, admissible_commands: cmds} = result) do
    commands = Enum.map_join(cmds, "\n", &"- #{&1}")
    done = Map.get(result, :done, false)
    score = Map.get(result, :score, 0)

    """
    Observation: #{obs}

    Admissible commands:
    #{commands}

    Done: #{done} | Score: #{score}\
    """
  end

  def format_result(other) when is_binary(other), do: other
  def format_result(other), do: inspect(other, pretty: true)

  @impl true
  def generate_tasks(count, env_config) do
    port_pid = env_config[:port_pid] || raise "ALFWorld requires :port_pid in env_config"

    case AlfPort.command(port_pid, %{cmd: "list_tasks"}) do
      {:ok, %{"tasks" => tasks}} ->
        seed = Map.get(env_config, :seed, 42)
        :rand.seed(:exsss, {seed, seed, seed})

        tasks
        |> Enum.shuffle()
        |> Enum.take(count)
        |> Enum.map(fn game_file ->
          %{
            game_file: game_file,
            port_pid: port_pid,
            goal: %{goal: "Complete the task in #{Path.basename(game_file)}"}
          }
        end)

      {:error, reason} ->
        raise "Failed to list ALFWorld tasks: #{inspect(reason)}"
    end
  end

  @impl true
  def generate_family_tasks(count, env_config) do
    # ALFWorld doesn't have a family/topology concept, delegate to generate_tasks
    generate_tasks(count, env_config)
  end

  @impl true
  def max_task_turns, do: 30

  @impl true
  def seed_design_source, do: nil

  @impl true
  def setup(opts) do
    python = Keyword.get(opts, :python, System.get_env("ALFWORLD_PYTHON", "python3"))
    split = Keyword.get(opts, :split, "eval_out_of_distribution")
    seed = Keyword.get(opts, :seed, 42)

    {:ok, port_pid} = AlfPort.start_link(python: python)

    case AlfPort.command(port_pid, %{cmd: "init", split: split}) do
      {:ok, %{"status" => "error", "error" => error}} ->
        AlfPort.stop(port_pid)
        raise "ALFWorld init failed: #{error}"

      {:ok, %{"task_count" => count}} ->
        IO.puts("ALFWorld initialized: #{count} games (split: #{split})")
        %{port_pid: port_pid, seed: seed, max_concurrency: 1}

      {:error, reason} ->
        AlfPort.stop(port_pid)
        raise "ALFWorld init failed: #{inspect(reason)}"
    end
  end

  @impl true
  def teardown(env_config) do
    if port_pid = env_config[:port_pid] do
      AlfPort.stop(port_pid)
    end

    :ok
  end

  # -- Private --

  defp extract_goal(obs) when is_binary(obs) do
    # ALFWorld observations typically start with the task description
    obs
    |> String.split("\n")
    |> Enum.find("", &String.contains?(&1, "Your task is"))
    |> String.trim()
    |> case do
      "" -> String.slice(obs, 0, 200)
      goal -> goal
    end
  end

  defp extract_goal(_), do: ""
end
