defmodule PtcRunner.Bench.Floor do
  @moduledoc false
  # Measures the idle resident floor of a started `:ptc_runner` with Mix off
  # the code path.
  #
  # Measuring the floor inside `mix run` reports a number no embedded host ever
  # pays: Mix and the compiler are resident, and they dominate `:code`. The
  # honest floor is a fresh VM that boots the application and nothing else, so
  # this spawns a child `elixir` over the same build path and asks it what it
  # actually loaded.

  @child_source """
  sample = fn ->
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    memory = :erlang.memory()
    loaded = :code.all_loaded()

    count_prefix = fn prefix ->
      Enum.count(loaded, fn {module, _file} ->
        String.starts_with?(Atom.to_string(module), prefix)
      end)
    end

    %{
      "total_bytes" => memory[:total],
      "processes_bytes" => memory[:processes],
      "code_bytes" => memory[:code],
      "ets_bytes" => memory[:ets],
      "atom_bytes" => memory[:atom],
      "loaded_modules" => length(loaded),
      "ptc_modules" => count_prefix.("Elixir.PtcRunner"),
      "mix_modules" => count_prefix.("Elixir.Mix"),
      "process_count" => :erlang.system_info(:process_count),
      "atom_count" => :erlang.system_info(:atom_count)
    }
  end

  {:ok, _started} = Application.ensure_all_started(:ptc_runner)
  idle = sample.()

  # Only a handful of PtcRunner modules are loaded at the idle floor. Lazy
  # module loading is the dominant one-shot cost, and it is invisible until
  # something runs, so the warm sample is the number a host actually settles
  # at rather than the one it boots at.
  {:ok, _step} = PtcRunner.Lisp.run("(+ 1 (* 2 3) (- 10 4))")
  warm = sample.()

  report = %{"idle" => idle, "warm" => warm}
  IO.puts("PTC_FLOOR " <> Base.encode64(:erlang.term_to_binary(report)))
  """

  @doc """
  Boots a child `elixir` over the current build path and returns its floor.

  Raises through `Mix.raise/1` rather than degrading to an in-VM measurement:
  a floor that silently includes Mix is the exact number this row exists to
  avoid publishing.
  """
  @spec measure!() :: %{binary() => %{binary() => integer()}}
  def measure! do
    args = Enum.flat_map(code_paths(), &["-pa", &1]) ++ ["-e", @child_source]

    case System.cmd(elixir_executable!(), args, stderr_to_stdout: true) do
      {output, 0} -> decode!(output)
      {output, status} -> Mix.raise("floor measurement child exited #{status}:\n#{output}")
    end
  end

  defp code_paths do
    Mix.Project.build_path()
    |> Path.join("lib/*/ebin")
    |> Path.wildcard()
    |> case do
      [] ->
        Mix.raise("no compiled applications under #{Mix.Project.build_path()}; run mix compile")

      paths ->
        paths
    end
  end

  defp elixir_executable! do
    System.find_executable("elixir") ||
      Mix.raise("`elixir` is not on PATH; the no-Mix floor row cannot be measured")
  end

  # The child prints on a tagged line so a warning from the boot (deprecations,
  # logger output) cannot be mistaken for the payload.
  defp decode!(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "PTC_FLOOR ", parts: 2) do
        [_prefix, encoded] -> encoded
        _no_tag -> nil
      end
    end)
    |> case do
      nil -> Mix.raise("floor measurement child printed no report:\n#{output}")
      encoded -> encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    end
  end
end
