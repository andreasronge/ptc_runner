defmodule PtcRunner.TestSupport.RunRecord do
  @moduledoc """
  ExUnit formatter that appends one JSON line per suite run to
  `PTC_TEST_RUN_LOG`.

  The line carries what a flake investigation needs and the console summary
  throws away once the terminal scrolls: the seed, the scheduler count, the
  wall/async/sync split that ExUnit prints as `Finished in`, and every failed
  test with its location and first line of failure. `scripts/ci/flake-hunt.sh`
  runs the suite repeatedly with this formatter and tabulates the file.

  The sync figure is the serial `async: false` phase and is the number that
  makes the suite slow; the async figure is what parallelism already buys.
  Track both per change rather than the summed per-test time, which hides the
  structure.
  """

  use GenServer

  @impl GenServer
  def init(config) do
    {:ok,
     %{
       log: Keyword.get(config, :run_log, System.get_env("PTC_TEST_RUN_LOG")),
       seed: Keyword.get(config, :seed),
       max_cases: Keyword.get(config, :max_cases),
       tests: 0,
       failures: []
     }}
  end

  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    state = %{state | tests: state.tests + 1}

    case test.state do
      {:failed, failures} ->
        {:noreply, %{state | failures: [failure(test, failures) | state.failures]}}

      {:invalid, _module} ->
        {:noreply, %{state | failures: [failure(test, :invalid) | state.failures]}}

      _passed_skipped_or_excluded ->
        {:noreply, state}
    end
  end

  def handle_cast({:suite_finished, times_us}, state) do
    append(state.log, record(state, times_us))
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @doc """
  Builds the record for one run from the formatter state and ExUnit's
  `times_us` map (`:run`, `:async`, `:load`).
  """
  @spec record(map(), map()) :: map()
  def record(state, times_us) do
    # `mix test` loads the files itself, so `:load` arrives as nil; `:async`
    # is nil when no async module ran.
    run_us = times_us[:run] || 0
    async_us = times_us[:async] || 0

    %{
      recorded_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      seed: state.seed,
      schedulers: System.schedulers_online(),
      max_cases: state.max_cases,
      wall_ms: div(run_us, 1_000),
      async_ms: div(async_us, 1_000),
      sync_ms: div(max(run_us - async_us, 0), 1_000),
      load_ms: div(times_us[:load] || 0, 1_000),
      tests: state.tests,
      failures: Enum.reverse(state.failures)
    }
  end

  defp failure(test, :invalid) do
    test |> location() |> Map.put(:message, "invalid: setup_all failed")
  end

  defp failure(test, failures) do
    message = Enum.map_join(failures, " | ", fn {_kind, reason, _stack} -> first_line(reason) end)

    test |> location() |> Map.put(:message, message)
  end

  defp location(test) do
    %{
      module: inspect(test.module),
      name: to_string(test.name),
      file: Path.relative_to_cwd(test.tags.file),
      line: test.tags.line
    }
  end

  defp first_line(%{__exception__: true} = exception) do
    exception |> Exception.message() |> first_line()
  end

  defp first_line(reason) when is_binary(reason) do
    reason |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 200)
  end

  defp first_line(reason), do: reason |> inspect(limit: 20) |> first_line()

  # A formatter exception aborts `mix test`, and a lost record must never
  # cost the run it describes, so every failure here is reported and dropped.
  defp append(path, _record) when path in [nil, ""], do: :ok

  defp append(path, record) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(record) <> "\n", [:append]) do
      IO.puts("\n[run-record] #{path}")
    else
      {:error, reason} ->
        IO.puts(:stderr, "\n[run-record] not written to #{path}: #{:file.format_error(reason)}")
    end
  rescue
    exception ->
      IO.puts(:stderr, "\n[run-record] not written to #{path}: #{Exception.message(exception)}")
  end
end
