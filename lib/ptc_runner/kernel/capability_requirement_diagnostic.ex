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
      when is_binary(singular_prefix) and is_binary(plural_prefix) do
    Enum.any?(templates(singular_prefix, plural_prefix), fn template ->
      DiagnosticPattern.valid_template?(template, message, fn values ->
        message(String.split(values.names, ", "), singular_prefix, plural_prefix)
      end)
    end)
  end

  def valid_message?(_message, _singular_prefix, _plural_prefix), do: false

  @spec message_schema(binary(), binary(), binary()) :: map()
  def message_schema(fallback, singular_prefix, plural_prefix) do
    %{
      "oneOf" => [
        %{"const" => fallback}
        | Enum.map(templates(singular_prefix, plural_prefix), fn template ->
            DiagnosticPattern.exact_message_schema(@max_message_bytes, template)
            |> Map.delete("minLength")
          end)
      ]
    }
  end

  @doc false
  @spec templates(binary(), binary()) :: [DiagnosticPattern.template()]
  def templates(singular_prefix, plural_prefix) do
    [
      [{:literal, singular_prefix}, {:slot, :names, :text, @symbol_pattern}],
      [
        {:literal, plural_prefix},
        {:slot, :names, :text, @symbol_pattern <> "(, #{@symbol_pattern}){1,7}"}
      ]
    ]
  end

  defp bounded_names(names) when is_list(names) and length(names) in 1..@max_names do
    if Enum.all?(names, &valid_name?/1), do: {:ok, names}, else: :error
  end

  defp bounded_names(_names), do: :error

  defp valid_name?(name),
    do: is_binary(name) and byte_size(name) <= @max_name_bytes and SymbolRef.valid_name?(name)

  defp render(names, singular_prefix, plural_prefix) do
    templates = templates(singular_prefix, plural_prefix)
    template = if length(names) == 1, do: hd(templates), else: List.last(templates)
    DiagnosticPattern.render(template, %{names: Enum.join(names, ", ")})
  end
end
