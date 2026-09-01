defmodule PtcRunner.TestSupport.CatalogTransport do
  @moduledoc false

  import ExUnit.Assertions

  alias PtcRunner.Lisp
  alias PtcRunner.TestSupport.MemorySoak

  @start_timeout_ms 5_000
  @stop_timeout_ms 5_000

  @doc """
  Runs `fun` while `count` sandbox evaluators are blocked inside a tool after
  catalog/prelude setup, then releases them.
  """
  @spec with_held_evaluators(pos_integer(), keyword(), (map() -> result)) :: result
        when result: term()
  def with_held_evaluators(count, run_opts, fun)
      when is_integer(count) and count > 0 and is_function(fun, 1) do
    owner = self()

    tools = %{
      "hold" => fn _arguments ->
        send(owner, {:evaluation_started, self()})
        receive do: (:release -> :ok)
      end
    }

    tasks =
      Enum.map(1..count, fn _index ->
        Task.async(fn ->
          Lisp.run_native(
            ~S|(tool/hold {})|,
            Keyword.merge(run_opts, tools: tools, timeout: 30_000, link: true)
          )
        end)
      end)

    {pids, started?} = take_started(count, [])

    result =
      try do
        case started? do
          :ok -> {:ok, fun.(%{tasks: tasks, pids: pids})}
          :timeout -> {:error, :startup_timeout}
        end
      catch
        kind, reason -> {:raise, kind, reason, __STACKTRACE__}
      end

    Enum.each(pids, &send(&1, :release))
    outcomes = collect_outcomes(tasks)
    finish_held_evaluators(result, outcomes)
  end

  @doc """
  Asserts concurrent live evaluators add less than two source-sized binaries
  relative to the same occupancy without a catalog.
  """
  @spec assert_shared_interned_bytes!(
          pos_integer(),
          keyword(),
          keyword(),
          pos_integer(),
          pos_integer()
        ) :: :ok
  def assert_shared_interned_bytes!(count, without_opts, with_opts, source_bytes, slack_bytes)
      when is_integer(count) and count > 0 and is_integer(source_bytes) and source_bytes > 0 and
             is_integer(slack_bytes) and slack_bytes >= 0 do
    MemorySoak.gc_everywhere()

    without_catalog =
      with_held_evaluators(count, without_opts, fn _held -> :erlang.memory(:binary) end)

    MemorySoak.gc_everywhere()

    with_catalog =
      with_held_evaluators(count, with_opts, fn _held -> :erlang.memory(:binary) end)

    delta = with_catalog - without_catalog
    limit = 2 * source_bytes + slack_bytes

    assert delta < limit,
           "catalog transport copied interned source " <>
             "(#{delta} extra binary bytes with #{count} live evaluators; " <>
             "limit #{limit} for #{source_bytes}-byte source)"

    :ok
  end

  defp finish_held_evaluators({:ok, value}, outcomes) do
    assert_clean_outcomes!(outcomes)
    value
  end

  defp finish_held_evaluators({:error, :startup_timeout}, _outcomes) do
    flunk("catalog transport evaluator did not start")
  end

  defp finish_held_evaluators({:raise, kind, reason, stacktrace}, _outcomes) do
    :erlang.raise(kind, reason, stacktrace)
  end

  defp take_started(0, acc), do: {Enum.reverse(acc), :ok}

  defp take_started(remaining, acc) do
    receive do
      {:evaluation_started, pid} when is_pid(pid) ->
        take_started(remaining - 1, [pid | acc])
    after
      @start_timeout_ms ->
        {Enum.reverse(acc), :timeout}
    end
  end

  defp collect_outcomes(tasks) do
    Enum.map(tasks, fn task ->
      Task.yield(task, @stop_timeout_ms) || Task.shutdown(task, :brutal_kill)
    end)
  end

  defp assert_clean_outcomes!(outcomes) do
    Enum.each(outcomes, fn
      {:ok, {:ok, _step}} ->
        :ok

      other ->
        flunk("held evaluator returned #{inspect(other)}")
    end)
  end
end
