defmodule PtcRunner.Kernel.WorkflowEnvironment do
  @moduledoc "Frozen workflow authority assembled only by the host."
  alias PtcRunner.Kernel.Environment
  @enforce_keys [:bundle, :capabilities, :data]
  defstruct [:bundle, :capabilities, :data]
  @type t :: %__MODULE__{}
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with false <- Keyword.keys(opts) -- [:bundle, :capabilities, :data] != [],
         {:ok, attributes} <-
           Environment.assemble(
             Keyword.get(opts, :bundle),
             Keyword.get(opts, :capabilities, []),
             Keyword.get(opts, :data, %{}),
             :workflow
           ) do
      {:ok, struct!(__MODULE__, attributes)}
    else
      true -> {:error, :unknown_environment_field}
      error -> error
    end
  end
end
