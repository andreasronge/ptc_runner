defmodule PtcRunner.Kernel.DeclaredReadEffectDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern

  @prefix "export `"
  @middle "` declares effect read but resolves to "
  @suffix "; change the declaration or use only read capabilities"
  @ref_pattern "[a-z][a-z0-9._-]{0,127}/[a-z][a-z0-9*+!_?.-]{0,127}"
  @effect_pattern "(?:write|unknown)"
  @message_pattern ~r/^export `([a-z][a-z0-9._-]{0,127}\/([a-z][a-z0-9*+!_?.-]{0,127}))` declares effect read but resolves to (write|unknown); change the declaration or use only read capabilities$/
  @maximum_message_bytes byte_size(@prefix) + 256 + byte_size(@middle) + 7 + byte_size(@suffix)

  @spec message(term(), term()) :: {:ok, binary()} | :error
  def message(ref, effect) when is_binary(ref) and effect in [:write, :unknown] do
    if Regex.match?(~r/^#{@ref_pattern}$/, ref) do
      {:ok, @prefix <> ref <> @middle <> Atom.to_string(effect) <> @suffix}
    else
      :error
    end
  end

  def message(_ref, _effect), do: :error

  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    case Regex.run(@message_pattern, message) do
      [_all, ref, _symbol, effect] ->
        message(ref, String.to_existing_atom(effect)) == {:ok, message}

      _no_match ->
        false
    end
  end

  def valid_message?(_message), do: false

  @spec message_schema(binary()) :: map()
  # ex_dna:disable-for-next-line — each dynamic diagnostic owns and validates its fallback
  def message_schema(fallback) when is_binary(fallback) do
    if not valid_message?(fallback), do: raise(ArgumentError, "invalid fallback message")

    DiagnosticPattern.exact_message_schema(@maximum_message_bytes, [
      {:literal, @prefix},
      {:pattern, @ref_pattern},
      {:literal, @middle},
      {:pattern, @effect_pattern},
      {:literal, @suffix}
    ])
  end
end
