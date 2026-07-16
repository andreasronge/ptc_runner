defmodule PtcRunner.Kernel.RunConfig do
  @moduledoc """
  The complete host-constructed configuration for one Kernel run.

  The required fields are:

  - `workflow_environment` — trusted outer workflow code and capabilities;
  - `mission_environment` — confined subordinate code and capabilities;
  - `input` — a JSON-like map exposed as the workflow evaluation context;
  - `limits` — normalized positive runtime ceilings;
  - `event_sink` — the bounded owner of canonical run events.

  Construction derives and freezes `mission_inventory` from the mission
  environment and limits. Hosts cannot supply mutable inventory text.

  `labels` is an optional bounded JSON-like map copied into `run-started`.
  Constructing a config validates shape and ownership objects but performs no
  execution and grants no authority beyond the supplied environments.
  """

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.MissionInventory
  alias PtcRunner.Kernel.WorkflowEnvironment

  @enforce_keys [
    :workflow_environment,
    :mission_environment,
    :input,
    :limits,
    :event_sink,
    :mission_inventory
  ]
  defstruct [
    :workflow_environment,
    :mission_environment,
    :input,
    :limits,
    :event_sink,
    :mission_inventory,
    labels: %{}
  ]

  @type t :: %__MODULE__{
          workflow_environment: WorkflowEnvironment.t(),
          mission_environment: MissionEnvironment.t(),
          input: map(),
          limits: Limits.t(),
          event_sink: EventSink.t(),
          mission_inventory: MissionInventory.t(),
          labels: map()
        }

  @spec new(keyword()) ::
          {:ok, t()} | {:error, :invalid_run_config | :mission_inventory_exceeded}
  @doc "Constructs a run configuration and rejects missing or unknown fields."
  def new(opts) when is_list(opts) do
    with false <-
           Keyword.keys(opts) --
             [:workflow_environment, :mission_environment, :input, :limits, :event_sink, :labels] !=
             [],
         %WorkflowEnvironment{} = workflow <- Keyword.get(opts, :workflow_environment),
         %MissionEnvironment{} = mission <- Keyword.get(opts, :mission_environment),
         true <- JSONValue.map?(Keyword.get(opts, :input)),
         %Limits{} = limits <- Keyword.get(opts, :limits),
         %EventSink{} = sink <- Keyword.get(opts, :event_sink),
         true <- labels?(Keyword.get(opts, :labels, %{})),
         {:ok, mission_inventory} <- MissionInventory.build(mission, limits) do
      {:ok,
       %__MODULE__{
         workflow_environment: workflow,
         mission_environment: mission,
         input: Keyword.fetch!(opts, :input),
         limits: limits,
         event_sink: sink,
         mission_inventory: mission_inventory,
         labels: Keyword.get(opts, :labels, %{})
       }}
    else
      {:error, :mission_inventory_exceeded} = error -> error
      _ -> {:error, :invalid_run_config}
    end
  end

  defp labels?(labels),
    do: JSONValue.map?(labels) and byte_size(:erlang.term_to_binary(labels)) <= 8_192
end
