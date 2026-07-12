defmodule PtcRunner.Kernel.Capability do
  @moduledoc """
  A host-owned capability route. Its callback is intentionally never projected
  into Lisp values or capability discovery metadata.
  """

  @name ~r|\A[a-z][a-z0-9._/-]{0,127}\z|
  @enforce_keys [:name, :callback]
  defstruct [:name, :callback, :validate, :description, model_visible: true]

  @type callback :: (map() -> {:ok, term()} | {:error, PtcRunner.Kernel.ProviderError.t()})
  @type t :: %__MODULE__{
          name: binary(),
          callback: callback(),
          validate: (map() -> :ok | {:error, binary()}) | nil,
          description: binary() | nil,
          model_visible: boolean()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_capability}
  def new(opts) when is_list(opts) do
    with {:ok, name} <- valid_name(Keyword.get(opts, :name)),
         callback when is_function(callback, 1) <- Keyword.get(opts, :callback),
         :ok <- valid_validator(Keyword.get(opts, :validate)),
         {:ok, description} <- valid_description(Keyword.get(opts, :description)),
         visible when is_boolean(visible) <- Keyword.get(opts, :model_visible, true) do
      {:ok,
       %__MODULE__{
         name: name,
         callback: callback,
         validate: Keyword.get(opts, :validate),
         description: description,
         model_visible: visible
       }}
    else
      _ -> {:error, :invalid_capability}
    end
  end

  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = capability) do
    %{
      name: capability.name,
      description: capability.description,
      model_visible: capability.model_visible
    }
  end

  defp valid_name(name) when is_binary(name) do
    if name =~ @name, do: {:ok, name}, else: {:error, :invalid_capability}
  end

  defp valid_name(_name), do: {:error, :invalid_capability}
  defp valid_validator(nil), do: :ok
  defp valid_validator(validate) when is_function(validate, 1), do: :ok
  defp valid_validator(_validate), do: {:error, :invalid_capability}
  defp valid_description(nil), do: {:ok, nil}

  defp valid_description(description)
       when is_binary(description) and byte_size(description) <= 4_096, do: {:ok, description}

  defp valid_description(_description), do: {:error, :invalid_capability}
end
