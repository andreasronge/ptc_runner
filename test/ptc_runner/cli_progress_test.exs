defmodule PtcRunner.CLIProgressTest do
  use ExUnit.Case, async: true

  alias PtcRunner.CLIProgress
  alias PtcRunner.CLIProgress.Format
  alias PtcRunner.Kernel.CommandPresentation
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.LiveStatus.Target

  test "interactive output pads a shorter update and finishes on a fresh line" do
    parent = self()
    writer = fn bytes -> send(parent, {:written, bytes}) end

    pid =
      CLIProgress.start(%{application: "/tmp/invoice-triage.json"},
        progress_writer: writer,
        progress_columns: fn -> {:ok, 80} end
      )

    assert_receive {:written, "invoice-triage.json\n\rpreparing 00:00"}

    send(pid, {:frame, frame(18_000, 21_000)})
    assert_receive {:written, first}
    assert first =~ "\rrunning 00:18"

    send(pid, {:frame, %{frame(19_000, 1_000) | parallel: nil, activity: []}})
    assert_receive {:written, second}
    assert String.ends_with?(second, " ")

    stop_progress(pid)

    assert_receive {:written, final}
    assert final =~ "\r"
    assert String.ends_with?(final, "\n")
  end

  test "redirected output has milestones without terminal control bytes and bounds heartbeats" do
    parent = self()
    writer = fn bytes -> send(parent, {:written, bytes}) end
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    pid =
      CLIProgress.start(%{application: "app.json"},
        progress_writer: writer,
        progress_columns: fn -> {:error, :enotsup} end,
        progress_clock: fn -> Agent.get(clock, & &1) end
      )

    assert_receive {:written, start}
    refute start =~ "\r"
    refute start =~ <<27>>

    send(pid, {:frame, frame(0, 20_000)})
    assert_receive {:written, milestone}
    refute milestone =~ "\r"
    send(pid, {:frame, frame(300, 19_700)})
    refute_receive {:written, _}
    Agent.update(clock, fn _ -> 9_999 end)
    send(pid, {:frame, frame(9_999, 10_001)})
    refute_receive {:written, _}
    Agent.update(clock, fn _ -> 10_000 end)
    send(pid, {:frame, frame(10_000, 10_000)})
    assert_receive {:written, heartbeat}
    assert heartbeat =~ "still running"
    refute heartbeat =~ "\r"
    stop_progress(pid)
  end

  test "narrow formatter retains priorities and concurrent agents are never a single counter" do
    one = frame(18_000, 21_000)
    assert Format.interactive(one, 42) =~ "running 00:18"
    assert Format.interactive(one, 42) =~ "21s left"

    assert Format.interactive(Map.put(one, :agents, [%{}, %{}]), 80) =~ "2 agents active"
  end

  test "formatter counts only canonical LLM requests and preserves exact spend" do
    frame = frame(1_000, 1_000)
    calls = %{workflow: %{"llm-request" => 3, "non-llm-cache" => 9}, mission: %{}}
    exact_cost = 9_007_199_254_740_991

    frame =
      put_in(frame, [:usage, :capability_calls], calls)
      |> put_in([:usage, :llm_spend, "total_cost", "microunits"], exact_cost)

    line = Format.interactive(frame, 200)
    assert line =~ "llm 3"
    assert line =~ "$9007199254.740991"

    assert Format.interactive(
             put_in(frame, [:usage, :llm_spend, "total_cost", "microunits"], 1_000_000),
             200
           ) =~ "$1"
  end

  test "a blocked stderr consumer cannot block startup or completion" do
    parent = self()

    writer = fn _bytes ->
      send(parent, {:writer_blocked, self()})
      receive do: (:never -> :ok)
    end

    startup =
      Task.async(fn ->
        pid =
          CLIProgress.start(%{application: "app.json"},
            progress_writer: writer,
            progress_columns: fn -> {:error, :enotsup} end
          )

        send(parent, {:progress_started, pid})
        receive do: (:finish -> CLIProgress.finish(pid, presentation()))
      end)

    # Keep the owner alive while proving startup returns despite blocked IO.
    assert_receive {:writer_blocked, pid}, 2_000
    assert_receive {:progress_started, ^pid}, 2_000
    ref = Process.monitor(pid)
    send(startup.pid, :finish)
    assert :ok = Task.await(startup, 2_000)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
  end

  test "early failure clears the preparing line and the title cannot inject controls" do
    parent = self()
    writer = fn bytes -> send(parent, {:written, bytes}) end

    pid =
      CLIProgress.start(%{application: "/tmp/bad\n\e[2J.json"},
        progress_writer: writer,
        progress_columns: fn -> {:ok, 80} end
      )

    assert_receive {:written, title}
    refute title =~ "\e"
    assert title =~ "bad??[2J.json"
    ref = Process.monitor(pid)
    assert :ok = CLIProgress.finish(pid, %{presentation() | exit_status: 3})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_receive {:written, cleanup}
    assert cleanup =~ String.duplicate(" ", String.length("preparing 00:00"))
  end

  test "redirected agent milestone uses the invocation suffix" do
    parent = self()
    writer = fn bytes -> send(parent, {:written, bytes}) end

    pid =
      CLIProgress.start(%{application: "app.json"},
        progress_writer: writer,
        progress_columns: fn -> :error end
      )

    assert_receive {:written, _}
    send(pid, {:frame, frame(0, 1_000)})
    assert_receive {:written, milestone}
    assert milestone =~ "agent a31f turn 2/6"
    stop_progress(pid)
  end

  test "redirected output corrects a successful Kernel frame when command publication fails" do
    parent = self()
    writer = fn bytes -> send(parent, {:written, bytes}) end

    pid =
      CLIProgress.start(%{application: "app.json"},
        progress_writer: writer,
        progress_columns: fn -> :error end
      )

    assert_receive {:written, _}
    send(pid, {:frame, %{phase: "ok", elapsed_ms: 10, usage: nil}})
    assert_receive {:written, completed}
    assert completed =~ "completed"

    ref = Process.monitor(pid)
    assert :ok = CLIProgress.finish(pid, %{presentation() | exit_status: 7})
    assert_receive {:written, failed}
    assert failed =~ "failed"
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "progress lifetime is bound to its initiating command process" do
    parent = self()

    owner =
      spawn(fn ->
        pid =
          CLIProgress.start(%{application: "app.json"},
            progress_writer: fn _bytes ->
              receive do: (:monitor_ready -> send(parent, :monitor_ready))
              receive do: (:never -> :ok)
            end,
            progress_columns: fn -> :error end
          )

        send(parent, {:owned_progress, pid})
        receive do: (:never -> :ok)
      end)

    assert_receive {:owned_progress, pid}
    ref = Process.monitor(pid)
    send(pid, :monitor_ready)
    assert_receive :monitor_ready
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  test "progress-process failure cannot terminate its initiating command" do
    parent = self()

    owner =
      spawn(fn ->
        pid =
          CLIProgress.start(%{application: "app.json"},
            progress_writer: fn _bytes -> :ok end,
            progress_columns: fn -> :error end
          )

        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^ref, :process, ^pid, :killed} -> :ok)
        send(parent, :owner_survived)
      end)

    ref = Process.monitor(owner)
    assert_receive :owner_survived
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
  end

  test "attachment preserves explicit target privacy and marks standalone progress for Viewer fan-out" do
    parent = self()
    writer = fn bytes -> send(parent, {:written, bytes}) end
    opts = [progress_writer: writer, progress_columns: fn -> :error end]
    progress = CLIProgress.start(%{application: "app.json"}, opts)
    assert_receive {:written, _}

    {:ok, explicit} = Target.new(fn _run_id, frame -> send(parent, {:explicit, frame}) end)
    {:ok, private_runtime} = CommandRuntime.new(live_status: explicit)
    assert {:ok, attached_private} = CLIProgress.attach(private_runtime, progress)
    refute Target.append_external?(attached_private.live_status)
    assert :ok = Target.report(attached_private.live_status, "run", frame(0, 1_000))
    assert_receive {:explicit, _}
    assert_receive {:written, _}
    stop_progress(progress)

    viewer_progress = CLIProgress.start(%{application: "app.json"}, opts)
    assert_receive {:written, _}
    {:ok, viewer_runtime} = CommandRuntime.new()
    assert {:ok, attached_viewer} = CLIProgress.attach(viewer_runtime, viewer_progress)
    assert Target.append_external?(attached_viewer.live_status)
    stop_progress(viewer_progress)
  end

  defp frame(elapsed, remaining) do
    %{
      phase: "running",
      elapsed_ms: elapsed,
      remaining_ms: remaining,
      limits: %{subordinate_evaluations: 128},
      usage: %{
        subordinate_evaluations: 2,
        capability_calls: %{workflow: %{"llm-request" => 3}, mission: %{}},
        llm_spend: %{
          "state" => "available",
          "total_cost" => %{"currency" => "USD", "microunits" => 2_631}
        }
      },
      parallel: %{held: 4, capacity: 8},
      activity: [%{kind: "agent", name: "agent-a31f", turn: 1, max_turns: 6, status: "tool-call"}]
    }
  end

  defp presentation do
    %CommandPresentation{
      stdout: "answer",
      stderr: "",
      exit_status: 0,
      outcome: nil,
      envelope_path: nil
    }
  end

  defp stop_progress(pid) do
    ref = Process.monitor(pid)
    assert :ok = CLIProgress.finish(pid, presentation())
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
