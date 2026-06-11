defmodule PtcRunner.TraceLog.IntrospectionProjectionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.TraceLog.Introspection

  @moduledoc """
  P2 of docs/plans/sandbox-heap-rebaseline.md: `log/` introspection closures
  are thin proxies to a host-side owner (sink or holder) that computes the
  projections, so the sandbox pays for the RESULT of each call — never for a
  copy, re-read, or in-sandbox traversal of the full log. Tool results' size,
  not the log's size, determines sandbox cost.
  """

  @default_max_heap 1_250_000

  # A turn-event list whose serialized size is ~`mb` megabytes: chunky program
  # sources make each event heavy, like real recorded sessions at scale.
  defp big_events(mb) do
    payload = String.duplicate("x", 10_000)
    count = mb * 100

    Enum.map(1..count, fn i ->
      %{
        "event" => "turn",
        "session_id" => "sess-#{rem(i, 5)}",
        "turn" => div(i, 5) + 1,
        "attempt" => div(i, 5) + 1,
        "committed" => true,
        "status" => "ok",
        "data" => %{
          "program" => "(def x-#{i} \"#{payload}\")",
          "result_preview" => "ok",
          "tool_calls" => []
        }
      }
    end)
  end

  describe "sandbox cost tracks result size, not log size" do
    test "a ~30MB event-list grant answers (count (log/sessions)) at ALL default limits" do
      events = big_events(30)
      tools = Introspection.tools(events)

      assert {:ok, step} =
               Lisp.run("(count (log/sessions))",
                 prelude: Introspection.prelude_source(),
                 tools: tools,
                 max_heap: @default_max_heap,
                 timeout: 10_000
               )

      assert step.return == 5
      # The grant must not have dragged the log into the sandbox baseline.
      assert step.usage.baseline_bytes < 5_000_000
    end

    test "per-session projection calls stay cheap across a big log" do
      events = big_events(10)
      tools = Introspection.tools(events)

      # One projection call per session — the shape that was quadratic-ish
      # pre-P2 (each call copied/traversed the full log in-sandbox).
      program = """
      (mapv (fn [s] (count (log/tool-calls (get s "correlation_id"))))
            (log/sessions))
      """

      assert {:ok, step} =
               Lisp.run(program,
                 prelude: Introspection.prelude_source(),
                 tools: tools,
                 max_heap: @default_max_heap,
                 timeout: 10_000
               )

      assert step.return == [0, 0, 0, 0, 0]
    end
  end

  describe "holder lifecycle and bounds" do
    test "an oversized event list is refused at grant time, not silently truncated" do
      events = big_events(2)

      assert_raise ArgumentError, ~r/exceeds.*max_bytes/i, fn ->
        Introspection.tools(events, max_bytes: 100_000)
      end
    end

    test "the holder dies with the process that created the grant" do
      parent = self()

      owner =
        spawn(fn ->
          tools = Introspection.tools(big_events(1))
          # The holder monitors its owner, so it shows up here — lets the
          # test await the holder's own exit deterministically.
          {:monitored_by, [holder]} = Process.info(self(), :monitored_by)
          send(parent, {:grant, tools, holder})

          receive do
            :exit -> :ok
          end
        end)

      assert_receive {:grant, tools, holder}, 5_000

      # Grant works while its owner lives...
      assert is_list(tools["log_sessions"].(%{}))

      holder_ref = Process.monitor(holder)
      send(owner, :exit)
      assert_receive {:DOWN, ^holder_ref, :process, ^holder, _}, 5_000

      # ...and fails with a clear recoverable error (not a hang, not a crash
      # of the calling process) once the owner is gone.
      assert_raise RuntimeError, ~r/no longer available/, fn ->
        tools["log_sessions"].(%{})
      end
    end
  end
end
