defmodule PtcRunner.Kernel.PreparationSeal do
  @moduledoc false

  alias PtcRunner.Kernel.Attestation

  @doc false
  @spec valid?(module(), term(), (term() -> boolean()), (term() -> term())) :: boolean()
  def valid?(module, %{attestation: attestation} = value, fields_valid?, payload)
      when is_atom(module) and is_function(fields_valid?, 1) and is_function(payload, 1) do
    Map.get(value, :__struct__) == module and fields_valid?.(value) and
      Attestation.valid?(module, payload.(value), attestation)
  end

  def valid?(_module, _value, _fields_valid?, _payload), do: false
end
