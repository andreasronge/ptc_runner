defmodule PtcRunner.Labs.PreludeSearch.Inputs do
  @moduledoc false

  def generate(subject, seed, count) do
    for index <- 0..(count - 1), do: input(subject, seed, index)
  end

  defp input("intervals", seed, index) do
    base = seed + index * 20
    gap = Integer.mod(seed + index, 4)

    %{
      "tolerance" => Integer.mod(seed + index, 3),
      "intervals" => [
        %{"start" => base + 8, "end" => base + 5},
        %{"start" => base, "end" => base + 3},
        %{"start" => base + 3 + gap, "end" => base + 6}
      ]
    }
    |> maybe_omit("tolerance", index)
  end

  defp input("normaliser", seed, index) do
    separators = [" ", ",", ".", "\n", "!"]
    separator = Enum.at(separators, Integer.mod(seed + index, length(separators)))
    short = if Integer.mod(index, 2) == 0, do: "A", else: "an"

    %{
      "text" => Enum.join(["", "Alpha", short, "BETA", "tail#{seed}-#{index}", ""], separator),
      "minimum_length" => Integer.mod(seed + index, 4)
    }
    |> maybe_omit("minimum_length", index)
  end

  defp input("reconciliation", seed, index) do
    offset = Integer.mod(seed + index, 11)
    equal = Integer.mod(index, 3) == 0

    %{
      "left" => [
        %{"id" => "shared", "amount" => 10 + offset},
        maybe_omit(%{"id" => "left-#{index}", "amount" => index}, "amount", index)
      ],
      "right" => [
        %{"id" => "shared", "amount" => 10 + offset + if(equal, do: 0, else: 1)},
        %{"id" => "right-#{index}", "amount" => seed + index}
      ]
    }
  end

  defp maybe_omit(map, key, index) do
    if rem(index, 5) == 0, do: Map.delete(map, key), else: map
  end
end
