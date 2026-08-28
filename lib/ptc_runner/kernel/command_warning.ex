defmodule PtcRunner.Kernel.CommandWarning do
  @moduledoc """
  Closed machine-readable warning published by command envelope V4.

  Warnings are non-terminal operator facts. They never contain credentials,
  provider payloads, or dependency errors. The installed provider alias and an
  adapter-attested public model selector are the only variable fields.
  """

  @message "the configured model is not an exact catalog entry; pricing, limits, token estimation, and capability detection may be incomplete"
  @identifier ~r/\A[a-z][a-z0-9._-]{0,127}\z/

  @enforce_keys [:code, :message, :provider, :model]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          code: :model_uncataloged,
          message: binary(),
          provider: binary(),
          model: binary() | nil
        }

  @spec model_uncataloged(binary(), binary() | nil) :: {:ok, t()} | :error
  def model_uncataloged(provider, model) do
    warning = %__MODULE__{
      code: :model_uncataloged,
      message: @message,
      provider: provider,
      model: model
    }

    if valid?(warning), do: {:ok, warning}, else: :error
  end

  @spec message() :: binary()
  def message, do: @message

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{
        code: :model_uncataloged,
        message: @message,
        provider: provider,
        model: model
      }) do
    valid_provider?(provider) and valid_model?(model)
  end

  def valid?(_warning), do: false

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = warning) do
    if valid?(warning) do
      %{
        "code" => Atom.to_string(warning.code),
        "message" => warning.message,
        "provider" => warning.provider,
        "model" => warning.model
      }
    else
      raise ArgumentError, "invalid command warning"
    end
  end

  @spec valid_map?(term()) :: boolean()
  def valid_map?(
        %{
          "code" => "model_uncataloged",
          "message" => @message,
          "provider" => provider,
          "model" => model
        } = warning
      )
      when map_size(warning) == 4 do
    valid_provider?(provider) and valid_model?(model)
  end

  def valid_map?(_warning), do: false

  @spec sort([t()]) :: [t()]
  def sort(warnings) when is_list(warnings) do
    warnings
    |> Enum.uniq_by(&{&1.code, &1.provider, &1.model})
    |> Enum.sort_by(&{&1.code, &1.provider, &1.model || ""})
  end

  defp valid_provider?(provider), do: is_binary(provider) and provider =~ @identifier

  defp valid_model?(nil), do: true

  defp valid_model?(model),
    do: is_binary(model) and byte_size(model) in 1..256 and String.valid?(model)
end
