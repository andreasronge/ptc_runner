defmodule Alma.Environment do
  @moduledoc """
  Behaviour for ALMA environments.

  An environment defines a task space where an agent can act,
  observe state, and achieve goals.

  ## Observation Summary

  Environments implement `summarize_observation/2` to interpret their own
  observation logs for trajectory analysis. This keeps the ALMA engine
  domain-blind — it aggregates generic summaries without knowing what
  "rooms" or "tickers" are.
  """

  @callback reset(config :: map()) :: state :: map()
  @callback step(state :: map(), action :: term()) :: {result :: map(), state :: map()}
  @callback observe(state :: map()) :: map()
  @callback success?(state :: map()) :: boolean()
  @callback context_schema() :: map()

  @doc """
  Summarize a single observation log entry for trajectory analysis.

  Takes an observation map (from `observation_log`) and the task's goal,
  and returns a map with:

  - `action_summary` — compact human-readable string, e.g. `"look(room_A)"`
  - `state_identifier` — a discrete representation of the agent's situation
    (for uniqueness counting), or `nil` if this action doesn't reveal state.
    Should be a finite, comparable value (e.g., room name, grid sector).
    Environments with continuous state spaces should quantize
    (e.g., `"sector_3_7"` not `"x=3.14159,y=7.28"`)
  - `discovery` — a string like `"found key!"` if the action discovered
    something relevant to the goal, or `nil`
  """
  @callback summarize_observation(observation :: map(), goal :: map()) :: %{
              action_summary: String.t(),
              state_identifier: String.t() | nil,
              discovery: String.t() | nil
            }

  @doc """
  Format a goal as a human-readable string for trajectory display.
  """
  @callback format_goal(goal :: map()) :: String.t()

  @doc """
  Returns the system prompt string for the task agent.
  May contain `{{goal}}` which is expanded by TaskAgent.
  """
  @callback task_prompt() :: String.t()

  @doc """
  Task interaction mode: `:tools` (default) or `:text`.

  In `:tools` mode, the agent uses SubAgent with tool calling.
  In `:text` mode, the agent runs a ReAct-style text loop —
  the LLM receives observations as user messages and responds
  with an action string. No tool schemas are sent.
  """
  @callback task_mode() :: :text | :tools

  @doc """
  Returns the tools map for the task agent (`:tools` mode only).

  `agent_pid` holds the mutable environment state.
  `knowledge` is the recall advice string from past episodes.
  """
  @callback task_tools(agent_pid :: pid(), knowledge :: String.t()) :: map()

  @doc """
  Format a step result map as text for the LLM (`:text` mode only).
  """
  @callback format_step_result(result :: map()) :: String.t()

  @doc """
  Parse the LLM's text response into an action for `step/2` (`:text` mode only).

  Returns the action string to pass to `step/2`.
  """
  @callback parse_action(response :: String.t(), state :: map()) :: String.t()

  @doc """
  Generates a batch of tasks for the environment.
  """
  @callback generate_tasks(count :: integer(), env_config :: map()) :: [map()]

  @doc """
  Generates a family batch of tasks (shared topology, different placement).
  Falls back to `generate_tasks/2` if not applicable.
  """
  @callback generate_family_tasks(count :: integer(), env_config :: map()) :: [map()]

  @doc """
  Returns PTC-Lisp source for the environment's seed baseline design,
  or nil if only the null baseline should be seeded.
  """
  @callback seed_design_source() :: String.t() | nil

  @doc """
  Build the environment config from user-provided options.

  Called once at the start of an ALMA run. Use this to start external
  processes (e.g. Python bridges) and include their pids in the returned
  config map.

  Default: passes through options as-is.
  """
  @callback setup(opts :: keyword()) :: map()

  @doc """
  Tear down any resources created by `setup/1`.

  Called once at the end of an ALMA run. Default: no-op.
  """
  @callback teardown(env_config :: map()) :: :ok

  @doc """
  Maximum turns the task agent should use per task.

  Default (when not implemented): 10.
  """
  @callback max_task_turns() :: pos_integer()

  @optional_callbacks [
    context_schema: 0,
    format_step_result: 1,
    max_task_turns: 0,
    parse_action: 2,
    seed_design_source: 0,
    setup: 1,
    task_mode: 0,
    task_tools: 2,
    teardown: 1
  ]
end
