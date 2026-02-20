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

  @optional_callbacks [context_schema: 0]
end
