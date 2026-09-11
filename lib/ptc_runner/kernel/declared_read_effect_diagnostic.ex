defmodule PtcRunner.Kernel.DeclaredReadEffectDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern
  alias PtcRunner.Lisp.Format.SymbolRef

  @prefix "export `"
  @middle "` declares effect read but resolves to "
  @suffix "; change the declaration or use only read capabilities"
  @symbol_chars "A-Za-z0-9+*\\/<>=?!_%.'&-"
  @ref_pattern "(?:[#{@symbol_chars}]{0,255}\/[#{@symbol_chars}]{0,255}|sha256:[0-9a-f]{64})"
  @effect_pattern "(?:write|unknown)"
  @message_pattern ~r/^export `((?:[A-Za-z0-9+*\/<>=?!_%.'&-]{0,255}\/[A-Za-z0-9+*\/<>=?!_%.'&-]{0,255}|sha256:[0-9a-f]{64}))` declares effect read but resolves to (write|unknown); change the declaration or use only read capabilities$/
  @maximum_message_bytes byte_size(@prefix) + 256 + byte_size(@middle) + 7 + byte_size(@suffix)

  @spec message(term(), term()) :: {:ok, binary()} | :error
  def message(ref, effect) when is_binary(ref) and effect in [:write, :unknown] do
    if valid_ref?(ref) do
      {:ok, @prefix <> display_ref(ref) <> @middle <> Atom.to_string(effect) <> @suffix}
    else
      :error
    end
  end

  def message(_ref, _effect), do: :error

  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    case Regex.run(@message_pattern, message) do
      [_all, ref, effect] ->
        valid_display_ref?(ref) and effect in ["write", "unknown"]

      _no_match ->
        false
    end
  end

  def valid_message?(_message), do: false

  defp valid_ref?(ref) do
    ref
    |> :binary.matches("/")
    |> Enum.any?(fn {index, 1} ->
      namespace = binary_part(ref, 0, index)
      symbol = binary_part(ref, index + 1, byte_size(ref) - index - 1)
      SymbolRef.valid_name?(namespace) and SymbolRef.valid_name?(symbol)
    end)
  end

  defp display_ref(ref) when byte_size(ref) <= 256, do: ref

  defp display_ref(ref),
    do: "sha256:" <> (:crypto.hash(:sha256, ref) |> Base.encode16(case: :lower))

  defp valid_display_ref?("sha256:" <> digest), do: digest =~ ~r/\A[0-9a-f]{64}\z/
  defp valid_display_ref?(ref), do: byte_size(ref) <= 256 and valid_ref?(ref)

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
