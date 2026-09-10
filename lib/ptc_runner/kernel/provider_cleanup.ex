defmodule PtcRunner.Kernel.ProviderCleanup do
  @moduledoc false

  @enforce_keys [:run, :provider]
  defstruct [:run, :provider, :transport, :grace_ms]

  @type t :: %__MODULE__{
          run: (-> term()),
          provider: binary(),
          transport: :stdio | :streamable_http | nil,
          grace_ms: pos_integer() | nil
        }

  @spec new((-> term()), binary(), map() | nil) :: t()
  def new(run, provider, context) when is_function(run, 0) and is_binary(provider) do
    context = context || %{}

    %__MODULE__{
      run: run,
      provider: provider,
      transport: Map.get(context, :transport),
      grace_ms: Map.get(context, :grace_ms)
    }
  end
end
