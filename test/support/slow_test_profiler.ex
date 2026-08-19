defmodule PtcRunner.TestSupport.SlowTestProfiler do
  @moduledoc false
  use GenServer

  @threshold_us 100_000

  @impl GenServer
  def init(_opts), do: {:ok, []}

  @impl GenServer
  def handle_cast({:test_finished, test}, acc) do
    {:noreply, [{test.time, test.module, test.name} | acc]}
  end

  def handle_cast({:suite_finished, _times}, acc), do: finish(acc)
  def handle_cast(_event, acc), do: {:noreply, acc}

  defp finish(acc) do
    slow =
      acc
      |> Enum.filter(fn {time, _module, _name} -> time >= @threshold_us end)
      |> Enum.sort_by(&elem(&1, 0), :desc)

    total_s = Enum.reduce(acc, 0, fn {time, _, _}, sum -> sum + time end) / 1_000_000
    slow_s = Enum.reduce(slow, 0, fn {time, _, _}, sum -> sum + time end) / 1_000_000

    path =
      System.get_env(
        "PTC_PROFILE_SLOW_OUT",
        Path.join(System.tmp_dir!(), "ptc-slow-tests.txt")
      )

    File.mkdir_p!(Path.dirname(path))

    lines =
      [
        "recorded=#{length(acc)} total=#{Float.round(total_s, 1)}s",
        ">=0.1s=#{length(slow)} sum=#{Float.round(slow_s, 1)}s",
        ""
        | Enum.map(slow, fn {time, module, name} ->
            "#{Float.round(time / 1_000_000, 3)}s  #{inspect(module)}  #{format_name(name)}"
          end)
      ]

    File.write!(path, Enum.join(lines, "\n") <> "\n")

    IO.puts(
      "\n[slow-profiler] #{path} (#{length(slow)} tests >= 0.1s, #{Float.round(slow_s, 1)}s)"
    )

    {:noreply, acc}
  end

  defp format_name(name) when is_atom(name), do: Atom.to_string(name)
  defp format_name(name) when is_binary(name), do: name
  defp format_name(name), do: inspect(name)
end
