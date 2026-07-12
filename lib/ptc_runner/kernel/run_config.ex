defmodule PtcRunner.Kernel.RunConfig do
  @moduledoc "The complete host-constructed configuration for one Kernel run."

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.WorkflowEnvironment

  @enforce_keys [:workflow_environment, :mission_environment, :input, :limits, :event_sink]
  defstruct [
    :workflow_environment,
    :mission_environment,
    :input,
    :limits,
    :event_sink,
    labels: %{}
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_run_config}
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
         true <- labels?(Keyword.get(opts, :labels, %{})) do
      {:ok,
       %__MODULE__{
         workflow_environment: workflow,
         mission_environment: mission,
         input: Keyword.fetch!(opts, :input),
         limits: limits,
         event_sink: sink,
         labels: Keyword.get(opts, :labels, %{})
       }}
    else
      _ -> {:error, :invalid_run_config}
    end
  end

  defp labels?(labels),
    do: JSONValue.map?(labels) and byte_size(:erlang.term_to_binary(labels)) <= 8_192
end
