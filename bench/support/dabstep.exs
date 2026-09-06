defmodule PtcRunner.Bench.DabstepSupport do
  @moduledoc false
  def prepared(source) do
    source
    |> String.replace("(defn- typed-cell [column value]", """
    (defn- column-kind [column]
      (cond
        (contains? (integer-columns) column) :integer
        (contains? (float-columns) column) :float
        (contains? (boolean-columns) column) :boolean
        :else :string))
    (defn- typed-cell [column kind value]
    """)
    |> String.replace(
      "(contains? (integer-columns) column) (parse-number",
      "(= kind :integer) (parse-number"
    )
    |> String.replace(
      "(contains? (float-columns) column) (parse-number",
      "(= kind :float) (parse-number"
    )
    |> String.replace(
      "(contains? (boolean-columns) column) (parse-boolean",
      "(= kind :boolean) (parse-boolean"
    )
    |> String.replace("[(get position c) c]", "[(get position c) c (column-kind c)]")
    |> String.replace(
      "(typed-cell (nth selector 1) (get",
      "(typed-cell (nth selector 1) (nth selector 2) (get"
    )
  end

  def capability(_event, measures, %{name: name}, table) do
    :ets.update_counter(table, name, [{2, 1}, {3, measures.duration_ms}], {name, 0, 0})
  end

  def measure(label, fun) do
    if System.get_env("DABSTEP_BENCH_PROFILE") do
      [to_string(:code.root_dir()), "lib", "tools-*", "ebin"]
      |> Path.join()
      |> Path.wildcard()
      |> hd()
      |> Code.append_path()

      IO.puts("PROFILE " <> label)
      apply(:tprof, :profile, [fun, %{type: :call_memory, rootset: :all, report: :total}])
    else
      samples(label, fun)
    end
  end

  defp samples(label, fun), do: Enum.each(0..5, &sample(label, &1, fun))

  def sample(label, sample, fun) do
    {gc0, words0, _} = :erlang.statistics(:garbage_collection)
    {us, result} = :timer.tc(fun)
    {gc1, words1, _} = :erlang.statistics(:garbage_collection)

    emit(%{
      experiment: label,
      sample: sample,
      wall_ms: us / 1000,
      gc_count: gc1 - gc0,
      reclaimed_words: words1 - words0,
      result: result
    })
  end

  defp emit(value), do: IO.puts(Jason.encode!(value))
end
