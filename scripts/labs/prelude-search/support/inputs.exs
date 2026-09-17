defmodule PtcRunner.Labs.PreludeSearch.Inputs do
  @moduledoc false

  def generate(subject, seed, count) do
    for index <- 0..(count - 1), do: input(subject, seed, index)
  end

  defp input("intervals", seed, index) do
    base = Integer.mod(seed * 17 + index * 7, 19)
    gap = Integer.mod(seed + index, 4)

    %{
      "tolerance" => Integer.mod(seed + index, 3),
      "intervals" => [
        %{"start" => base + 8, "end" => base + 5},
        %{"start" => base, "end" => base + 3},
        %{"start" => base + 3 + gap, "end" => base + 6}
      ]
    }
  end

  defp input("normaliser", seed, index) do
    separators = [" ", ",", ".", "\n", "!"]
    separator = Enum.at(separators, Integer.mod(seed + index, length(separators)))
    short = if Integer.mod(index, 2) == 0, do: "A", else: "an"

    %{
      "text" => Enum.join(["Alpha", short, "BETA", "tail"], separator),
      "minimum_length" => 1 + Integer.mod(seed + index, 3)
    }
  end

  defp input("reconciliation", seed, index) do
    offset = Integer.mod(seed + index, 11)
    equal = Integer.mod(index, 3) == 0

    %{
      "left" => [
        %{"id" => "shared", "amount" => 10 + offset},
        %{"id" => "left-#{index}", "amount" => index}
      ],
      "right" => [
        %{"id" => "shared", "amount" => 10 + offset + if(equal, do: 0, else: 1)},
        %{"id" => "right-#{index}", "amount" => seed + index}
      ]
    }
  end
end
