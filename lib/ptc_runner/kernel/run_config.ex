defmodule PtcRunner.Kernel.RunConfig do
  @moduledoc "The complete host-constructed configuration for one Kernel run."

  alias PtcRunner.Kernel.EventSink
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
         true <- json_map?(Keyword.get(opts, :input)),
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
    do: json_map?(labels) and byte_size(:erlang.term_to_binary(labels)) <= 8_192

  defp json_map?(map) when is_map(map) and not is_struct(map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and json_value?(value) end)

  defp json_map?(_map), do: false
  defp json_value?(nil), do: true
  defp json_value?(value) when is_boolean(value) or is_number(value) or is_binary(value), do: true
  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  defp json_value?(value) when is_map(value) and not is_struct(value), do: json_map?(value)
  defp json_value?(_value), do: false
end
