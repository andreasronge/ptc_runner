defmodule PtcRunner.Kernel.ProviderCleanup do
  @moduledoc false

  @enforce_keys [:run, :provider]
  defstruct [:run, :snapshot, :provider, :transport, :grace_ms]

  @type t :: %__MODULE__{
          run: (-> term()),
          snapshot: (-> map()) | nil,
          provider: binary(),
          transport: :stdio | :streamable_http | nil,
          grace_ms: pos_integer() | nil
        }

  @spec new((-> term()), (-> map()) | nil, binary(), map() | nil) :: t()
  def new(run, snapshot, provider, context)
      when is_function(run, 0) and (is_function(snapshot, 0) or is_nil(snapshot)) and
             is_binary(provider) do
    context = context || %{}

    %__MODULE__{
      run: run,
      snapshot: snapshot,
      provider: provider,
      transport: Map.get(context, :transport),
      grace_ms: Map.get(context, :grace_ms)
    }
  end
end
