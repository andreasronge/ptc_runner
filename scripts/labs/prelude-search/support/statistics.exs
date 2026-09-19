defmodule PtcRunner.Labs.PreludeSearch.Statistics do
  @moduledoc false

  @replicates 2_000
  @seed {2026, 9, 19}

  def compare(rows, baseline, conditions) do
    keys = Enum.map(rows, &{&1["experiment"], &1["subject"], &1["seed"]})

    if length(keys) != MapSet.size(MapSet.new(keys)),
      do: raise(ArgumentError, "duplicate experiment case")

    base = index(rows, baseline)
    Enum.map(conditions, fn condition -> comparison(base, index(rows, condition), condition) end)
  end

  defp index(rows, condition) do
    rows
    |> Enum.filter(&(&1["experiment"] == condition))
    |> Map.new(&{{&1["subject"], &1["seed"]}, if(&1["solved"], do: 1, else: 0)})
  end

  defp comparison(base, candidate, condition) do
    if map_size(base) == 0 or MapSet.new(Map.keys(base)) != MapSet.new(Map.keys(candidate)) do
      %{"condition" => condition, "status" => "incomplete_pairs"}
    else
      pairs =
        Enum.sort(base)
        |> Enum.map(fn {{subject, seed} = key, value} ->
          %{
            "subject" => subject,
            "seed" => seed,
            "baseline" => value,
            "candidate" => candidate[key],
            "difference" => candidate[key] - value
          }
        end)

      strata =
        pairs
        |> Enum.group_by(& &1["subject"], & &1["difference"])
        |> Enum.sort()
        |> Enum.map(&elem(&1, 1))

      {samples, _state} =
        Enum.map_reduce(1..@replicates, :rand.seed_s(:exsss, @seed), fn _, state ->
          {draws, state} =
            Enum.map_reduce(strata, state, fn values, state ->
              Enum.map_reduce(values, state, fn _, state ->
                {index, state} = :rand.uniform_s(length(values), state)
                {Enum.at(values, index - 1), state}
              end)
            end)

          {mean(List.flatten(draws)), state}
        end)

      sorted = Enum.sort(samples)

      %{
        "condition" => condition,
        "status" => "descriptive_pilot",
        "pairs" => pairs,
        "observed" => mean(Map.values(candidate)),
        "baseline" => mean(Map.values(base)),
        "difference" => mean(Enum.map(pairs, & &1["difference"])),
        "interval_95" => [Enum.at(sorted, 49), Enum.at(sorted, 1949)],
        "method" => "stratified paired percentile bootstrap",
        "replicates" => @replicates,
        "bootstrap_seed" => Tuple.to_list(@seed),
        "verdict" => "inconclusive"
      }
    end
  end

  defp mean(values), do: Enum.sum(values) / length(values)
end
