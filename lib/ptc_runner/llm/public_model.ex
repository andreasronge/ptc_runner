defmodule PtcRunner.LLM.PublicModel do
  @moduledoc false

  # The adapter must attest the exact bounded selector before it may be public.
  # Pricing diagnostics and the facade share this policy without calling each other.

  @doc false
  @spec attested(module(), String.t()) :: String.t() | nil
  def attested(adapter, model) when is_atom(adapter) and is_binary(model) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :public_model, 1) do
      case adapter.public_model(model) do
        {:ok, ^model}
        when byte_size(model) in 1..256 ->
          if String.valid?(model), do: model

        _private_or_invalid ->
          nil
      end
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  def attested(_adapter, _model), do: nil
end
