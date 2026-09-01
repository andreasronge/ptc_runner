defmodule PtcRunner.Kernel.CandidateRefusedDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.DiagnosticPattern

  @fallback "the candidate was refused by the promotion gate"
  @ids ~w(G1 G2 G3 G4)
  @ids_pattern "(?:G1(?:, G2)?(?:, G3)?(?:, G4)?|G2(?:, G3)?(?:, G4)?|G3(?:, G4)?|G4)"
  @max_message_bytes byte_size(@fallback <> " (G1, G2, G3, G4)")

  @spec message(map()) :: binary()
  def message(%{criteria: criteria}) when is_list(criteria) do
    format(unresolved_ids(criteria))
  end

  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message) do
    case parse_ids(message) do
      {:ok, ids} -> format(ids) == message
      :error -> false
    end
  end

  def valid_message?(_message), do: false

  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    if fallback != @fallback, do: raise(ArgumentError, "invalid fallback message")

    %{
      "oneOf" => [
        %{"const" => fallback},
        DiagnosticPattern.exact_message_schema(@max_message_bytes, [
          {:literal, fallback <> " ("},
          {:pattern, @ids_pattern},
          {:literal, ")"}
        ])
      ]
    }
  end

  defp unresolved_ids(criteria) do
    fails = criterion_ids(criteria, :fail)
    if fails != [], do: fails, else: criterion_ids(criteria, :blocked)
  end

  defp criterion_ids(criteria, status) do
    criteria
    |> Enum.filter(&(&1.status == status and &1.id in @ids))
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp format([]), do: @fallback
  defp format(ids), do: @fallback <> " (" <> Enum.join(ids, ", ") <> ")"

  defp parse_ids(@fallback), do: {:ok, []}

  defp parse_ids(message) do
    prefix = @fallback <> " ("

    with true <- String.starts_with?(message, prefix),
         true <- String.ends_with?(message, ")"),
         inner <-
           binary_part(
             message,
             byte_size(prefix),
             byte_size(message) - byte_size(prefix) - 1
           ),
         ids when ids != [] <- String.split(inner, ", "),
         true <- ids == Enum.uniq(ids),
         true <- ids == Enum.sort(ids),
         true <- Enum.all?(ids, &(&1 in @ids)) do
      {:ok, ids}
    else
      _invalid -> :error
    end
  end
end
