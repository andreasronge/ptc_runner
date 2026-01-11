defmodule PtcRunner.SubAgent.Namespace.Data do
  @moduledoc "Renders the data/ namespace section."

  alias PtcRunner.Lisp.Format
  alias PtcRunner.SubAgent.Namespace.TypeVocabulary

  @doc """
  Render data/ namespace section for USER message.

  Returns `nil` for empty data maps, otherwise a formatted string with header
  and entries showing type label and truncated sample.

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.Data.render(%{})
      nil

      iex> PtcRunner.SubAgent.Namespace.Data.render(%{count: 42})
      ";; === data/ ===\\ndata/count                    ; integer, sample: 42"
  """
  @spec render(map()) :: String.t() | nil
  def render(data) when map_size(data) == 0, do: nil

  def render(data) do
    lines =
      data
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, value} ->
        type_label = TypeVocabulary.type_of(value)
        sample = format_sample(value)
        "data/#{name}                    ; #{type_label}, sample: #{sample}"
      end)

    [";; === data/ ===" | lines] |> Enum.join("\n")
  end

  defp format_sample(value) do
    {str, _truncated} = Format.to_clojure(value, limit: 3, printable_limit: 80)
    str
  end
end
