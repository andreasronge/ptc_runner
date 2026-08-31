defmodule PtcRunner.Kernel.CapabilityRequirementDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern
  alias PtcRunner.Lisp.Format.SymbolRef

  @max_names 8
  @max_name_bytes 128
  @max_message_bytes 1_100
  @symbol_first "[A-Za-z+*\\/<>=?!_%.&-]"
  @symbol_rest "[A-Za-z0-9+*\\/<>=?!_%.&'-]"
  @symbol_pattern @symbol_first <> @symbol_rest <> "{0,127}"

  @spec message(term(), binary(), binary()) :: {:ok, binary()} | :error
  def message(names, singular_prefix, plural_prefix)
      when is_binary(singular_prefix) and is_binary(plural_prefix) do
    with {:ok, names} <- bounded_names(names),
         true <- names == Enum.sort(Enum.uniq(names)),
         message <- render(names, singular_prefix, plural_prefix),
         true <- byte_size(message) <= @max_message_bytes do
      {:ok, message}
    else
      _invalid -> :error
    end
  end

  @spec valid_message?(term(), binary(), binary()) :: boolean()
  def valid_message?(message, singular_prefix, plural_prefix)
      when is_binary(message) and is_binary(singular_prefix) and is_binary(plural_prefix) do
    names =
      cond do
        String.starts_with?(message, singular_prefix) ->
          [String.replace_prefix(message, singular_prefix, "")]

        String.starts_with?(message, plural_prefix) ->
          message |> String.replace_prefix(plural_prefix, "") |> String.split(", ")

        true ->
          []
      end

    message(names, singular_prefix, plural_prefix) == {:ok, message}
  end

  def valid_message?(_message, _singular_prefix, _plural_prefix), do: false

  @spec message_schema(binary(), binary(), binary()) :: map()
  def message_schema(fallback, singular_pattern_prefix, plural_pattern_prefix) do
    %{
      "oneOf" => [
        %{"const" => fallback},
        dynamic_schema(singular_pattern_prefix <> @symbol_pattern),
        dynamic_schema(plural_pattern_prefix <> @symbol_pattern <> "(, #{@symbol_pattern}){1,7}")
      ]
    }
  end

  defp bounded_names(names) when is_list(names) and length(names) in 1..@max_names do
    if Enum.all?(names, &valid_name?/1), do: {:ok, names}, else: :error
  end

  defp bounded_names(_names), do: :error

  defp valid_name?(name),
    do: is_binary(name) and byte_size(name) <= @max_name_bytes and SymbolRef.valid_name?(name)

  defp render([name], singular_prefix, _plural_prefix), do: singular_prefix <> name
  defp render(names, _singular_prefix, plural_prefix), do: plural_prefix <> Enum.join(names, ", ")

  defp dynamic_schema(pattern) do
    %{
      "type" => "string",
      "maxLength" => @max_message_bytes,
      "pattern" => DiagnosticPattern.exact(pattern)
    }
  end
end
