defmodule PtcRunner.Kernel.AnalysisSessionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.AnalysisAssembly
  alias PtcRunner.Kernel.AnalysisSession
  alias PtcRunner.Kernel.AnalysisSessionBuilder
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.MissionInventory
  alias PtcRunner.Kernel.PublicRunAnalysisProfile
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.SessionTrace
  alias PtcRunner.Kernel.TraceLog

  @lifecycle_timeout_ms 30_000

  @tag :tmp_dir
  test "fixed profile exposes only run analysis authority and a deterministic identity", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, first, first_info} =
             start_log_session({:directory, directory}, {:directory, directory})

    assert {:ok, second, second_info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn ->
      AnalysisSession.abort(first, :test_cleanup)
      AnalysisSession.abort(second, :test_cleanup)
      AnalysisSession.stop(first)
      AnalysisSession.stop(second)
    end)

    assert first_info.profile_id == "run-analysis-v1"
    assert first_info.profile_digest == second_info.profile_digest

    assert first_info.profile_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert first_info.namespaces == ["analysis", "cap"]
    refute inspect(first_info) =~ directory

    forged = %{first | token: make_ref()}
    assert {:error, :run_analysis_session_closed} = AnalysisSession.info(forged)

    first_state = :sys.get_state(first.pid)
    identity = first_state.profile.identity
    remaining_before_timer_read = RunState.remaining_ms(first_state.run_state)

    assert Process.read_timer(first_state.timer) <=
             remaining_before_timer_read + 10

    assert identity["profile_id"] == "run-analysis-v1"
    assert identity["components"] == ["cap", "analysis"]
    assert identity["explicit_capabilities"] == PublicRunAnalysisProfile.explicit_capabilities()

    assert identity["implicit_runtime"] == %{
             "version" => 1,
             "routes" => ~w(cap-describe cap-list runtime-remaining runtime-usage)
           }

    assert first_state.run_state.pid == first_state.config.event_sink.pid

    assert identity["implicit_runtime"]["routes"] ==
             first_state.run_state
             |> RuntimeTools.tools(
               first_state.config.missions["default"].environment,
               first_state.config.event_sink,
               :mission
             )
             |> Map.keys()
             |> Enum.sort()

    assert identity["persistence_policy"] == "canonical-trace-on-close"
    assert identity["result_policy"] == "bounded-json-v1"

    assert Map.keys(identity["limits"]) |> Enum.sort() ==
             PublicRunAnalysisProfile.limits()
             |> Map.from_struct()
             |> Map.keys()
             |> Enum.map(&to_string/1)
             |> Enum.sort()

    refute inspect(identity) =~ directory
    refute inspect(identity) =~ "#Function<"
    refute inspect(:sys.get_status(first.pid)) =~ directory
    refute inspect(:sys.get_status(:sys.get_state(first.pid).session_trace.pid)) =~ directory

    assert {:ok, %{status: :ok, value: capabilities}} =
             AnalysisSession.evaluate(first, "(tool/cap-list {})")

    assert Enum.map(capabilities, & &1["name"]) ==
             PublicRunAnalysisProfile.explicit_capabilities()

    assert {:ok, %{status: :ok, value: usage}} =
             AnalysisSession.evaluate(first, "(tool/runtime-usage {})")

    assert is_integer(usage["remaining_ms"])

    for source <- [
          "(tool/workspace.read {})",
          "(tool/llm-request {})",
          "(tool/kernel-eval {})",
          "(tool/workflow-annotate {})"
        ] do
      assert {:ok, %{status: :error, outcome: :evaluation_error}} =
               AnalysisSession.evaluate(first, source)
    end
  end

  @tag :tmp_dir
  test "session startup independently rejects a sealed custom mission", %{tmp_dir: directory} do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    state = :sys.get_state(session.pid)
    original = state.config.missions["default"].environment.capabilities["analysis-runs"]
    forged = %{original | callback: fn _arguments -> {:ok, %{"items" => []}} end}

    capabilities =
      state.config.missions["default"].environment.capabilities
      |> Map.put("analysis-runs", forged)
      |> Map.values()

    assert {:ok, mission} =
             MissionEnvironment.new(
               bundle: state.config.missions["default"].environment.bundle,
               capabilities: capabilities,
               data: %{}
             )

    assert {:ok, inventory} = MissionInventory.build(mission, state.config.limits)

    config = %{
      state.config
      | missions:
          Map.put(state.config.missions, "default", %{
            environment: mission,
            inventory: inventory
          })
    }

    assembly =
      AnalysisAssembly.seal(
        config,
        state.profile,
        state.resources,
        state.session_trace,
        state.run_state
      )

    assert {:error, :invalid_run_analysis_assembly} = AnalysisSession.start(assembly)
  end

  @tag :tmp_dir
  test "replaying an attached assembly is rejected without emitting another run start", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    state = :sys.get_state(session.pid)

    assembly =
      AnalysisAssembly.seal(
        state.config,
        state.profile,
        state.resources,
        state.session_trace,
        state.run_state
      )

    starts_before =
      state.config.event_sink
      |> EventSink.events()
      |> Enum.count(&(&1.type == "run-started"))

    assert {:error, _reason} = AnalysisSession.start(assembly)

    assert state.config.event_sink
           |> EventSink.events()
           |> Enum.count(&(&1.type == "run-started")) == starts_before
  end

  @tag :tmp_dir
  test "session trace construction binds limits, destination, and sink run identity", %{
    tmp_dir: directory
  } do
    limits = PublicRunAnalysisProfile.limits()
    reserve = EventSink.terminal_reserve(:normal, limits)

    assert {:ok, run_state, sink} =
             RunState.start_with_event_sink(
               limits,
               [
                 run_id: "bound-run",
                 trace_id: "bound-run",
                 fail_closed: true,
                 terminal_reserve: reserve
               ],
               owner: self()
             )

    on_exit(fn ->
      stop_run_state(run_state)
    end)

    common = [
      owner: self(),
      destination_directory_identity: directory_identity(directory),
      run_state: run_state,
      event_sink: sink
    ]

    assert {:error, :session_trace_failed} =
             SessionTrace.start(
               limits,
               Path.join(directory, "wrong.jsonl"),
               "bound-run",
               common
             )

    assert {:error, :session_trace_failed} =
             SessionTrace.start(
               limits,
               Path.join(directory, "other-run.jsonl"),
               "other-run",
               common
             )

    {:ok, narrower} = Limits.new(subordinate_evaluations: 1)

    assert {:error, :session_trace_failed} =
             SessionTrace.start(
               narrower,
               Path.join(directory, "bound-run.jsonl"),
               "bound-run",
               common
             )
  end

  @tag :tmp_dir
  test "session trace construction rejects missing reserve and non-open recorder state", %{
    tmp_dir: directory
  } do
    limits = PublicRunAnalysisProfile.limits()
    reserve = EventSink.terminal_reserve(:normal, limits)

    starts = [
      {"zero-reserve", [fail_closed: true, terminal_reserve: %{count: 0, bytes: 0}],
       fn _run_state, _sink -> :ok end},
      {"finalized", [fail_closed: true, terminal_reserve: reserve],
       fn _run_state, sink ->
         assert {:ok, _batch} = EventSink.finalize_and_events(sink, %{outcome: :error})
         :ok
       end},
      {"closed", [fail_closed: true, terminal_reserve: reserve],
       fn run_state, _sink ->
         RunState.close(run_state)
       end}
    ]

    Enum.each(starts, fn {run_id, sink_opts, prepare} ->
      assert {:ok, run_state, sink} =
               RunState.start_with_event_sink(
                 limits,
                 [run_id: run_id, trace_id: run_id] ++ sink_opts,
                 owner: self()
               )

      on_exit(fn ->
        stop_run_state(run_state)
      end)

      assert :ok = prepare.(run_state, sink)

      assert {:error, :session_trace_failed} =
               SessionTrace.start(
                 limits,
                 Path.join(directory, run_id <> ".jsonl"),
                 run_id,
                 owner: self(),
                 destination_directory_identity: directory_identity(directory),
                 run_state: run_state,
                 event_sink: sink
               )
    end)
  end

  @tag :tmp_dir
  test "public result ceiling preserves the authoritative committed continuation effect", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    source = ~S|(loop [s "\\" n 0] (if (= n 19) s (recur (str s s) (inc n))))|

    # The result ceiling builds its own error map rather than going through the
    # ordinary projection, so it carries the redaction flag independently.
    assert {:ok,
            %{
              status: :error,
              outcome: :result_exceeded,
              continuation_effect: :committed_with_history,
              error: %{
                kind: :result_exceeded,
                message: "public evaluation result exceeded its byte limit",
                message_redacted?: false
              }
            }} = AnalysisSession.evaluate(session, source)

    assert {:ok,
            %{
              status: :error,
              outcome: :result_exceeded,
              continuation_effect: :committed_without_history
            }} = AnalysisSession.evaluate(session, "(return *1)")

    assert {:ok, %{status: :ok, outcome: :returned, value: 524_288}} =
             AnalysisSession.evaluate(session, "(return (count *1))")
  end

  @tag :tmp_dir
  test "large non-JSON values have bounded human formatting", %{tmp_dir: directory} do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    assert {:ok,
            %{
              status: :ok,
              outcome: :returned,
              value: nil,
              value_available?: false,
              formatted: formatted,
              formatted_truncated?: true,
              formatted_caps_hit: caps_hit,
              formatted_sampled_keys: []
            }} =
             AnalysisSession.evaluate(
               session,
               "(return (set (range 0 10000)))"
             )

    assert is_binary(formatted)
    assert byte_size(formatted) <= 65_536
    assert :items in caps_hit
  end

  @tag :tmp_dir
  test "profile sessions honor a configurable structural preview ceiling", %{tmp_dir: directory} do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session(
               {:directory, directory},
               {:directory, directory},
               preview_chars: 256
             )

    on_exit(fn -> AnalysisSession.stop(session) end)

    payload = String.duplicate("x", 10_000)
    source = ~s|(return {"payload" "#{payload}" "status" "ok" "trace_id" "trace-1"})|

    assert {:ok,
            %{
              status: :ok,
              outcome: :returned,
              formatted: formatted,
              formatted_truncated?: true,
              formatted_sampled_keys: sampled_keys
            }} = AnalysisSession.evaluate(session, source)

    assert String.length(formatted) <= 256
    assert sampled_keys == ["payload", "status", "trace_id"]
    assert formatted =~ "preview truncated"
    refute formatted =~ String.duplicate("x", 100)
  end

  @tag :tmp_dir
  test "JSON projection preserves novel keyword and string keys without silent collapse", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    assert {:ok,
            %{
              status: :ok,
              outcome: :returned,
              value: nil,
              value_available?: false,
              formatted: formatted
            }} =
             AnalysisSession.evaluate(
               session,
               ~S|(return {:zzzz_collision 1 "zzzz_collision" 2})|
             )

    assert formatted =~ ":zzzz_collision 1"
    assert formatted =~ ~S|"zzzz_collision" 2|
  end

  @tag :tmp_dir
  test "prints survive a post-execution continuation commit rejection", %{tmp_dir: directory} do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    source =
      ~S|(loop [s "xx" n 0] (if (= n 20) (do (println "before-history-reject") s) (recur (str s s) (inc n))))|

    assert {:ok,
            %{
              status: :error,
              outcome: :history_exceeded,
              continuation_effect: :preserved,
              prints: ["before-history-reject"]
            }} = AnalysisSession.evaluate(session, source)
  end

  @tag :tmp_dir
  test "public print projection bounds empty-print cardinality and encoded size", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    source = "(do " <> String.duplicate("(println) ", 256) <> "nil)"

    assert {:ok,
            %{
              status: :ok,
              outcome: :continued,
              prints: prints,
              prints_truncated?: true
            } = result} = AnalysisSession.evaluate(session, source)

    assert length(prints) == 128
    assert Enum.all?(prints, &(&1 == ""))
    assert byte_size(Jason.encode!(prints)) <= 65_536

    assert byte_size(Jason.encode!(result)) <=
             PublicRunAnalysisProfile.limits().terminal_result_bytes
  end

  @tag :tmp_dir
  test "session evaluation has direct detailed Evaluation parity", %{tmp_dir: directory} do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    session_state = :sys.get_state(session.pid)
    {:ok, direct_state} = RunState.start(session_state.config.limits)

    {:ok, direct_sink} =
      EventSink.start(:normal, session_state.config.limits, run_id: "direct-parity")

    on_exit(fn ->
      AnalysisSession.stop(session)
      stop_run_state(direct_state)
      EventSink.stop(direct_sink)
    end)

    sources = [
      "(def x 40)",
      "(+ x 2)",
      "(return (+ *1 x))",
      "(fail \"stop\")",
      "missing"
    ]

    Enum.each(sources, fn source ->
      direct =
        Evaluation.evaluate_source(
          direct_state,
          "default",
          session_state.config.missions["default"].environment,
          source,
          session_state.config.limits.evaluation_timeout_ms,
          direct_sink
        )

      assert {:ok, session_result} = AnalysisSession.evaluate(session, source)
      assert session_result.outcome == direct.outcome
      assert session_result.continuation_effect == direct.continuation_effect

      stopped =
        session_state.config.event_sink
        |> EventSink.events()
        |> Enum.find(fn event ->
          event.type == "evaluation-stopped" and
            event.data.evaluation_id == session_result.evaluation_id
        end)

      assert stopped.data.duration_ms == session_result.duration_ms
    end)

    assert RunState.evaluation_memory_summary(direct_state) ==
             RunState.evaluation_memory_summary(:sys.get_state(session.pid).run_state)

    direct_calls = RunState.usage(direct_state).capability_calls.mission
    session_calls = RunState.usage(:sys.get_state(session.pid).run_state).capability_calls.mission
    assert direct_calls == session_calls

    direct_types =
      direct_sink
      |> EventSink.events()
      |> Enum.map(& &1.type)

    session_types =
      session_state.config.event_sink
      |> EventSink.events()
      |> Enum.map(& &1.type)
      |> Enum.reject(&(&1 == "run-started"))

    assert session_types == direct_types
  end

  @tag :tmp_dir
  test "multi-turn mission semantics preserve exact history and keep return and fail open", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    assert {:ok,
            %{
              status: :ok,
              outcome: :continued,
              value: 40,
              continuation_effect: :committed_with_history
            }} = AnalysisSession.evaluate(session, "40")

    assert {:ok, %{outcome: :continued, value: 41}} =
             AnalysisSession.evaluate(session, "(+ *1 1)")

    assert {:ok,
            %{
              status: :ok,
              outcome: :returned,
              value: 81,
              continuation_effect: :committed_without_history
            }} = AnalysisSession.evaluate(session, "(return (+ *1 *2))")

    assert {:ok,
            %{
              status: :error,
              outcome: :failed,
              value: "stop",
              continuation_effect: :preserved
            }} =
             AnalysisSession.evaluate(
               session,
               "(do (def leaked 99) (println \"failed-print\") (fail \"stop\"))"
             )

    assert {:ok, %{outcome: :evaluation_error, continuation_effect: :preserved}} =
             AnalysisSession.evaluate(session, "leaked")

    assert {:ok, %{outcome: :returned, value: [41, 40]}} =
             AnalysisSession.evaluate(session, "(return [*1 *2])")

    assert {:ok, %{lifecycle: :open}} = AnalysisSession.info(session)
  end

  @tag :tmp_dir
  test "explicit capability failures retain their activity classification", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    assert {:ok,
            %{
              status: :error,
              outcome: :failed,
              error: %{
                capability_activity?: true,
                capability_failure?: true,
                retryable?: true
              }
            }} =
             AnalysisSession.evaluate(
               session,
               ~S|(fail (tool/analysis-runs {"unsupported" true}))|
             )
  end

  @tag :tmp_dir
  test "analysis queries the frozen capture and public accounting is authoritative", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    assert {:ok, %{status: :ok, value: %{"items" => items}, usage: usage}} =
             AnalysisSession.evaluate(session, "(analysis/runs {})")

    assert Enum.map(items, & &1["run_id"]) == ["seed"]

    assert Map.keys(hd(items)) |> Enum.sort() ==
             ~w(complete duration_ms evaluations llm_calls run_id status terminal_reason truncated)

    assert Map.keys(usage.capability_calls) |> Enum.sort() ==
             PublicRunAnalysisProfile.explicit_capabilities()

    assert usage.mission_calls.used == 1
    assert usage.capability_calls["analysis-runs"] == %{used: 1, limit: 256, remaining: 255}

    assert {:ok, info} = AnalysisSession.info(session)
    assert info.usage.capability_calls == usage.capability_calls

    assert {:ok, %{status: :ok, value: counters, usage: counter_usage}} =
             AnalysisSession.evaluate(session, "(analysis/counters {})")

    assert counters["runs"] == 1
    assert is_list(counters["llm_usage_by_model"])
    assert counters["unattributed_model_calls"] == 0
    refute Map.has_key?(counters, "status")

    assert counter_usage.capability_calls["analysis-counters"] == %{
             used: 1,
             limit: 256,
             remaining: 255
           }

    assert {:ok, %{status: :error, outcome: :failed}} =
             AnalysisSession.evaluate(session, ~S|(analysis/counters {"unsupported" true})|)

    seed_trace(directory, "later")

    assert {:ok, %{value: %{"items" => still_frozen}}} =
             AnalysisSession.evaluate(session, "(analysis/runs {})")

    assert Enum.map(still_frozen, & &1["run_id"]) == ["seed"]

    assert {:ok, %{value: still_frozen_counters}} =
             AnalysisSession.evaluate(session, "(analysis/counters {})")

    assert still_frozen_counters["runs"] == 1

    assert {:ok, %{value: %{"items" => [full]}}} =
             AnalysisSession.evaluate(session, ~S|(analysis/runs {"view" "full"})|)

    assert full["trace_id"] == "seed"
    assert full["schema_version"] == 2
  end

  @tag :tmp_dir
  test "run analysis rejects invalid limits and returns bounded pages", %{
    tmp_dir: directory
  } do
    for run_id <- ~w(first second third), do: seed_trace(directory, run_id)

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    assert {:ok, %{status: :error, outcome: :failed}} =
             AnalysisSession.evaluate(session, ~S|(analysis/runs {"limit" 1001})|)

    assert {:ok,
            %{
              status: :ok,
              value: %{"truncated" => true, "items" => [first], "next_cursor" => cursor}
            }} =
             AnalysisSession.evaluate(
               session,
               ~S|(analysis/runs {"limit" 1})|
             )

    assert first["run_id"] in ~w(first second third)
    assert is_binary(cursor)

    assert {:ok, %{value: %{"items" => from_first_page}}} =
             AnalysisSession.evaluate(
               session,
               ~s|(analysis/runs {"limit" 2 "cursor" "#{cursor}"})|
             )

    assert [first["run_id"] | Enum.map(from_first_page, & &1["run_id"])] |> Enum.sort() ==
             ~w(first second third)
  end

  @tag :tmp_dir
  test "builder publishes into an explicit output directory without mutating its source", %{
    tmp_dir: directory
  } do
    source = Path.join(directory, "source")
    output = Path.join(directory, "output")
    File.mkdir!(source)
    File.mkdir!(output)
    seed_trace(source, "seed")

    assert {:ok, session, info} =
             start_log_session({:directory, source}, {:directory, output})

    on_exit(fn -> AnalysisSession.stop(session) end)
    assert {:ok, %{lifecycle: :closed}} = AnalysisSession.close(session)
    assert File.ls!(source) == ["seed.jsonl"]
    assert File.ls!(output) == [info.session_id <> ".jsonl"]
    assert String.starts_with?(info.session_id, "run-analysis-")
  end

  @tag :tmp_dir
  test "session persistence rejects a replaced output-directory identity", %{
    tmp_dir: directory
  } do
    source = Path.join(directory, "source")
    output = Path.join(directory, "output")
    displaced = Path.join(directory, "displaced")
    File.mkdir!(source)
    File.mkdir!(output)
    seed_trace(source, "seed")

    assert {:ok, session, info} =
             start_log_session({:directory, source}, {:directory, output})

    on_exit(fn -> AnalysisSession.stop(session) end)
    File.rename!(output, displaced)
    File.mkdir!(output)

    assert {:error, :trace_persistence_failed} = AnalysisSession.close(session)
    refute File.exists?(Path.join(output, info.session_id <> ".jsonl"))
    assert File.ls!(output) == []
  end

  @tag :tmp_dir
  test "close publishes one reloadable canonical run and is idempotent", %{tmp_dir: directory} do
    seed_trace(directory, "seed")

    assert {:ok, session, info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    secret_source = "(do (def private-source-sentinel 3) (+ private-source-sentinel 0))"
    assert {:ok, %{outcome: :continued}} = AnalysisSession.evaluate(session, secret_source)
    assert {:ok, %{lifecycle: :closed} = closed} = AnalysisSession.close(session)
    assert {:ok, ^closed} = AnalysisSession.close(session)
    assert {:error, :session_closed} = AnalysisSession.evaluate(session, "42")

    path = Path.join(directory, info.session_id <> ".jsonl")
    assert File.regular?(path)
    refute File.read!(path) =~ "private-source-sentinel"
    refute File.read!(path) =~ secret_source
    assert {:ok, trace} = TraceLog.new(source: {:file, path})

    assert {:ok, %{"run_id" => run_id, "status" => "ok"} = run} =
             TraceLog.query(trace, :get_run, %{"run_id" => info.session_id})

    assert run_id == info.session_id

    assert run["session_profile"] == %{
             "id" => info.profile_id,
             "digest" => info.profile_digest
           }

    assert {:ok, %{"items" => turns}} =
             TraceLog.query(trace, :list_turns, %{"run_id" => info.session_id})

    assert Enum.count(turns, &(&1["type"] == "run-stopped")) == 1
  end

  @tag :tmp_dir
  test "a refreshed session captures the preceding analysis trace", %{tmp_dir: directory} do
    seed_trace(directory, "seed")

    assert {:ok, first, first_info} =
             start_log_session({:directory, directory}, {:directory, directory})

    assert {:ok, _closed} = AnalysisSession.close(first)
    AnalysisSession.stop(first)

    assert {:ok, second, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(second) end)

    assert {:ok, %{value: %{"items" => runs}}} =
             AnalysisSession.evaluate(second, "(analysis/runs {})")

    assert Enum.map(runs, & &1["run_id"]) |> Enum.sort() ==
             Enum.sort(["seed", first_info.session_id])
  end

  @tag :tmp_dir
  test "persistence failure retains one terminal batch for close retry", %{tmp_dir: directory} do
    seed_trace(directory, "seed")
    {:ok, faults} = Agent.start_link(fn -> 0 end)

    hook = fn
      :after_sync ->
        Agent.get_and_update(faults, fn
          0 -> {{:error, :injected}, 1}
          count -> {:ok, count + 1}
        end)

      _stage ->
        :ok
    end

    assert {:ok, session, info} =
             start_log_session({:directory, directory}, {:directory, directory},
               persistence_fault_hook: hook
             )

    on_exit(fn -> AnalysisSession.stop(session) end)

    open_state = :sys.get_state(session.pid)
    run_state_pid = open_state.run_state.pid
    snapshot_pid = open_state.snapshot.pid

    assert {:error, :trace_persistence_failed} = AnalysisSession.close(session)
    assert {:ok, %{lifecycle: :persistence_failed}} = AnalysisSession.info(session)
    refute Process.alive?(run_state_pid)
    refute Process.alive?(snapshot_pid)
    refute File.exists?(Path.join(directory, info.session_id <> ".jsonl"))

    assert {:ok, %{lifecycle: :closed}} = AnalysisSession.close(session)
    assert File.regular?(Path.join(directory, info.session_id <> ".jsonl"))
  end

  @tag :tmp_dir
  test "evaluation ceiling returns one terminal result and rejects later work", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    for value <- 1..PublicRunAnalysisProfile.limits().subordinate_evaluations do
      assert {:ok, %{status: :ok, outcome: :continued}} =
               AnalysisSession.evaluate(session, Integer.to_string(value))
    end

    assert {:ok,
            %{
              status: :error,
              outcome: :limit_exceeded,
              continuation_effect: :preserved,
              error: %{reason: :subordinate_evaluations},
              usage: %{evaluations: %{used: 64, remaining: 0}}
            }} = AnalysisSession.evaluate(session, "65")

    assert {:ok, %{lifecycle: :terminal_unpersisted, terminal_reason: :subordinate_evaluations}} =
             AnalysisSession.info(session)

    assert {:error, :session_terminal} = AnalysisSession.evaluate(session, "66")
    assert {:ok, %{lifecycle: :closed}} = AnalysisSession.close(session)

    assert {:ok, trace} =
             TraceLog.new(source: {:file, Path.join(directory, info.session_id <> ".jsonl")})

    assert {:ok, %{"status" => "error", "terminal_reason" => "subordinate_evaluations"}} =
             TraceLog.query(trace, :get_run, %{"run_id" => info.session_id})
  end

  @tag :tmp_dir
  test "deadline expiry closes and persists without another evaluation request", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    send(session.pid, :deadline_expired)
    assert {:ok, %{lifecycle: :open}} = AnalysisSession.info(session)

    deadline_token = :sys.get_state(session.pid).deadline_token
    send(session.pid, {:deadline_expired, deadline_token})

    assert {:ok, %{lifecycle: :closed}} = AnalysisSession.info(session)
    assert File.regular?(Path.join(directory, info.session_id <> ".jsonl"))
  end

  @tag :tmp_dir
  test "an elapsed deadline closes identically before accepting a queued evaluation", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, info} =
             start_log_session({:directory, directory}, {:directory, directory})

    state = :sys.get_state(session.pid)

    :sys.replace_state(state.run_state.pid, fn run_state ->
      %{run_state | deadline_ms: System.monotonic_time(:millisecond) - 1}
    end)

    assert {:error, :session_closed} = AnalysisSession.evaluate(session, "42")

    assert {:ok, %{lifecycle: :closed, evaluation_count: 0}} =
             AnalysisSession.info(session)

    path = Path.join(directory, info.session_id <> ".jsonl")
    assert {:ok, trace} = TraceLog.new(source: {:file, path})

    assert {:ok, %{"status" => "ok"}} =
             TraceLog.query(trace, :get_run, %{"run_id" => info.session_id})

    AnalysisSession.stop(session)
  end

  @tag :tmp_dir
  test "abort and expiry preserve an existing terminal budget reason", %{tmp_dir: directory} do
    seed_trace(directory, "seed")

    for closure <- [:abort, :expiry] do
      assert {:ok, session, info} =
               start_log_session({:directory, directory}, {:directory, directory})

      on_exit(fn -> AnalysisSession.stop(session) end)
      exhaust_protocol_budget(session)

      assert {:ok, %{lifecycle: :terminal_unpersisted, terminal_reason: :protocol_errors}} =
               AnalysisSession.info(session)

      case closure do
        :abort ->
          assert {:ok, %{lifecycle: :closed}} =
                   AnalysisSession.abort(session, :viewer_shutdown)

        :expiry ->
          deadline_token = :sys.get_state(session.pid).deadline_token
          send(session.pid, {:deadline_expired, deadline_token})
          assert {:ok, %{lifecycle: :closed}} = AnalysisSession.info(session)
      end

      path = Path.join(directory, info.session_id <> ".jsonl")
      assert {:ok, trace} = TraceLog.new(source: {:file, path})

      assert {:ok, %{"status" => "error", "terminal_reason" => "protocol_errors"}} =
               TraceLog.query(trace, :get_run, %{"run_id" => info.session_id})
    end
  end

  @tag :tmp_dir
  test "terminal protocol budget rejects later work but remains persistable", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    for _attempt <- 1..32 do
      assert {:ok, %{outcome: :continued}} =
               AnalysisSession.evaluate(session, "(tool/runtime-usage {\"bad\" true})")
    end

    assert {:ok,
            %{
              status: :error,
              outcome: :limit_exceeded,
              continuation_effect: :preserved,
              error: %{kind: :limit_exceeded, reason: :protocol_errors}
            }} =
             AnalysisSession.evaluate(session, "(tool/runtime-usage {\"bad\" true})")

    assert {:ok, %{lifecycle: :terminal_unpersisted, terminal_reason: :protocol_errors}} =
             AnalysisSession.info(session)

    assert {:error, :session_terminal} = AnalysisSession.evaluate(session, "42")
    assert {:ok, %{lifecycle: :closed}} = AnalysisSession.close(session)

    path = Path.join(directory, info.session_id <> ".jsonl")
    assert File.regular?(path)
    assert {:ok, trace} = TraceLog.new(source: {:file, path})

    assert {:ok, %{"status" => "error", "terminal_reason" => "protocol_errors"}} =
             TraceLog.query(trace, :get_run, %{"run_id" => info.session_id})
  end

  @tag :tmp_dir
  test "trace-owner death fail-closes state and releases session resources", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    state = :sys.get_state(session.pid)

    trace_ref = Process.monitor(state.session_trace.pid)
    run_state_ref = Process.monitor(state.run_state.pid)
    snapshot_ref = Process.monitor(state.snapshot.pid)

    Process.exit(state.session_trace.pid, :kill)

    assert_receive {:DOWN, ^trace_ref, :process, _pid, :killed}

    assert_receive {:DOWN, ^run_state_ref, :process, _pid, run_state_reason}
                   when run_state_reason in [:normal, :noproc]

    assert_receive {:DOWN, ^snapshot_ref, :process, _pid, snapshot_reason}
                   when snapshot_reason in [:normal, :noproc]

    assert {:ok, %{lifecycle: :backend_failed, terminal_reason: :event_sink_error}} =
             AnalysisSession.info(session)

    assert {:error, :backend_failed} = AnalysisSession.evaluate(session, "42")
    AnalysisSession.stop(session)
  end

  @tag :tmp_dir
  test "combined runtime death during evaluation cannot commit or publish", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()

    assert {:ok, session, info} =
             start_log_session({:directory, directory}, {:directory, directory},
               evaluation_hook: fn :after_evaluation_started ->
                 send(parent, :evaluation_started)

                 receive do
                   :continue_evaluation -> :ok
                 end
               end
             )

    state = :sys.get_state(session.pid)
    sink_ref = Process.monitor(state.config.event_sink.pid)
    session_ref = Process.monitor(session.pid)
    trace_ref = Process.monitor(state.session_trace.pid)

    evaluation = Task.async(fn -> AnalysisSession.evaluate(session, "(def committed 42)") end)
    assert_receive :evaluation_started

    Process.exit(state.config.event_sink.pid, :kill)
    assert_receive {:DOWN, ^sink_ref, :process, _pid, :killed}
    assert %{persistence: :backend_failed} = SessionTrace.info(state.session_trace)
    send(session.pid, :continue_evaluation)

    assert {:error, :session_closed} = Task.await(evaluation)
    assert_receive {:DOWN, ^session_ref, :process, _pid, _reason}
    assert_receive {:DOWN, ^trace_ref, :process, _pid, :normal}
    refute File.exists?(Path.join(directory, info.session_id <> ".jsonl"))
  end

  @tag :tmp_dir
  test "builder death during post-start handoff cleans every constructed owner", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()

    builder =
      spawn(fn ->
        result =
          start_log_session({:directory, directory}, {:directory, directory},
            construction_hook: fn :session_started, resources ->
              send(parent, {:construction_started, resources})

              receive do
                :finish_construction -> :ok
              end
            end
          )

        send(parent, {:builder_result, result})
      end)

    builder_ref = Process.monitor(builder)
    assert_receive {:construction_started, resources}, 5_000

    session_ref = Process.monitor(resources.session.pid)
    trace_ref = Process.monitor(resources.session_trace.pid)
    snapshot_ref = Process.monitor(resources.snapshot.pid)
    run_state = :sys.get_state(resources.session.pid).run_state
    run_state_ref = Process.monitor(run_state.pid)

    Process.exit(builder, :kill)

    assert_receive {:DOWN, ^builder_ref, :process, ^builder, :killed}
    assert_receive {:DOWN, ^session_ref, :process, _pid, :killed}
    assert_receive {:DOWN, ^trace_ref, :process, _pid, :normal}
    assert_receive {:DOWN, ^snapshot_ref, :process, _pid, :normal}
    assert_receive {:DOWN, ^run_state_ref, :process, _pid, :normal}
    refute_received {:builder_result, _result}
  end

  @tag :tmp_dir
  test "builder death while final release is queued cannot orphan the completed session", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()

    builder =
      spawn(fn ->
        result =
          start_log_session({:directory, directory}, {:directory, directory},
            builder_fault_hook: fn
              :before_builder_release, resources ->
                send(parent, {:before_builder_release, resources, self()})

                receive do
                  :queue_builder_release -> :ok
                end

              _stage, _resources ->
                :ok
            end
          )

        send(parent, {:release_race_builder_result, result})
      end)

    builder_ref = Process.monitor(builder)
    assert_receive {:before_builder_release, resources, ^builder}, 5_000
    session_ref = Process.monitor(resources.session.pid)
    trace_ref = Process.monitor(resources.session_trace.pid)
    runtime_ref = Process.monitor(resources.run_state.pid)
    snapshot_ref = Process.monitor(resources.snapshot.pid)

    :erlang.suspend_process(resources.session_trace.pid)

    try do
      send(builder, :queue_builder_release)

      await_process_message(resources.session_trace.pid, fn
        {:"$gen_call", {^builder, _tag}, {_token, :complete_construction}} -> true
        _message -> false
      end)

      Process.exit(builder, :kill)
      assert_receive {:DOWN, ^builder_ref, :process, ^builder, :killed}
    after
      :erlang.resume_process(resources.session_trace.pid)
    end

    assert_receive {:DOWN, ^session_ref, :process, _pid, _reason}, 1_000
    assert_receive {:DOWN, ^runtime_ref, :process, _pid, _reason}, 1_000
    assert_receive {:DOWN, ^snapshot_ref, :process, _pid, _reason}, 1_000
    assert_receive {:DOWN, ^trace_ref, :process, _pid, _reason}, @lifecycle_timeout_ms
    refute_received {:release_race_builder_result, _result}
  end

  @tag :tmp_dir
  test "trace death during post-start handoff cannot orphan the partial session", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()

    starter =
      Task.async(fn ->
        start_log_session({:directory, directory}, {:directory, directory},
          construction_hook: fn :session_started, resources ->
            send(parent, {:handoff_started, resources, self()})

            receive do
              :finish_handoff -> :ok
            end
          end
        )
      end)

    assert_receive {:handoff_started, resources, builder}, 1_000
    session_ref = Process.monitor(resources.session.pid)
    trace_ref = Process.monitor(resources.session_trace.pid)

    Process.exit(resources.session_trace.pid, :kill)
    assert_receive {:DOWN, ^trace_ref, :process, _pid, :killed}
    send(builder, :finish_handoff)

    assert {:error, _reason} = Task.await(starter)
    assert_receive {:DOWN, ^session_ref, :process, _pid, _reason}, 1_000
  end

  @tag :tmp_dir
  test "trace exit during final construction completion cannot orphan the session", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()

    starter =
      Task.async(fn ->
        start_log_session({:directory, directory}, {:directory, directory},
          builder_fault_hook: fn
            :before_builder_release, resources ->
              send(parent, {:final_completion_ready, resources, self()})

              receive do
                :finish_final_completion -> :ok
              end

            _stage, _resources ->
              :ok
          end
        )
      end)

    assert_receive {:final_completion_ready, resources, builder}, 1_000
    session_ref = Process.monitor(resources.session.pid)
    trace_ref = Process.monitor(resources.session_trace.pid)
    Process.exit(resources.session_trace.pid, :kill)
    assert_receive {:DOWN, ^trace_ref, :process, _pid, :killed}
    send(builder, :finish_final_completion)

    assert {:error, :run_analysis_session_failed} = Task.await(starter)
    assert_receive {:DOWN, ^session_ref, :process, _pid, _reason}, 1_000
  end

  @tag :tmp_dir
  test "trace death before run-state ownership transfer cleans the builder-owned runtime", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()

    builder =
      spawn(fn ->
        result =
          start_log_session({:directory, directory}, {:directory, directory},
            builder_fault_hook: fn
              :before_run_state_transfer, resources ->
                send(parent, {:before_run_state_transfer, resources, self()})

                receive do
                  :finish_transfer -> :ok
                end

              _stage, _resources ->
                :ok
            end
          )

        send(parent, {:pre_transfer_builder_result, result})

        receive do
          :stop_builder -> :ok
        end
      end)

    on_exit(fn -> Process.exit(builder, :kill) end)
    builder_ref = Process.monitor(builder)
    assert_receive {:before_run_state_transfer, resources, ^builder}, @lifecycle_timeout_ms
    trace_ref = Process.monitor(resources.session_trace.pid)
    runtime_ref = Process.monitor(resources.run_state.pid)
    snapshot_ref = Process.monitor(resources.snapshot.pid)

    Process.exit(resources.session_trace.pid, :kill)
    assert_receive {:DOWN, ^trace_ref, :process, _pid, :killed}, @lifecycle_timeout_ms
    send(builder, :finish_transfer)

    assert_receive {:pre_transfer_builder_result, {:error, _reason}}, @lifecycle_timeout_ms
    assert_receive {:DOWN, ^runtime_ref, :process, _pid, _reason}, @lifecycle_timeout_ms
    assert_receive {:DOWN, ^snapshot_ref, :process, _pid, _reason}, @lifecycle_timeout_ms
    refute_received {:DOWN, ^builder_ref, :process, ^builder, _reason}
    send(builder, :stop_builder)
    assert_receive {:DOWN, ^builder_ref, :process, ^builder, :normal}, @lifecycle_timeout_ms
  end

  @tag :tmp_dir
  test "session init failure after attachment performs construction cleanup without publication",
       %{
         tmp_dir: directory
       } do
    seed_trace(directory, "seed")
    parent = self()

    starter =
      Task.async(fn ->
        builder = self()

        start_log_session({:directory, directory}, {:directory, directory},
          builder_fault_hook: fn
            :after_session_attach, resources ->
              send(parent, {:session_attached, resources, builder, self()})

              receive do
                :finish_session_init -> :ok
              end

            _stage, _resources ->
              :ok
          end
        )
      end)

    assert_receive {:session_attached, resources, builder, session_pid}, 5_000
    trace_ref = Process.monitor(resources.session_trace.pid)
    snapshot_ref = Process.monitor(resources.snapshot.pid)
    :erlang.suspend_process(builder)

    try do
      Process.exit(resources.snapshot.pid, :kill)
      assert_receive {:DOWN, ^snapshot_ref, :process, _pid, :killed}
      send(session_pid, :finish_session_init)
      assert_receive {:DOWN, ^trace_ref, :process, _pid, :normal}
    after
      :erlang.resume_process(builder)
    end

    assert {:error, _reason} = Task.await(starter)
    assert Enum.sort(File.ls!(directory)) == ["seed.jsonl"]
  end

  @tag :tmp_dir
  test "info waits behind an accepted evaluation instead of reporting a live session closed", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory},
               evaluation_hook: fn :after_evaluation_started ->
                 send(parent, {:evaluation_barrier, self()})

                 receive do
                   :finish_evaluation -> :ok
                 end
               end
             )

    on_exit(fn -> AnalysisSession.stop(session) end)
    evaluation = Task.async(fn -> AnalysisSession.evaluate(session, "42") end)
    assert_receive {:evaluation_barrier, session_pid}
    info = Task.async(fn -> AnalysisSession.info(session) end)
    # The evaluation is deterministically parked at the barrier (`:finish_evaluation`
    # is sent below, only AFTER this yield), so `info` can never complete within the
    # window regardless of its length — a short window keeps `is_nil(yielded)` true.
    yielded = Task.yield(info, 200)
    send(session_pid, :finish_evaluation)

    assert {:ok, %{status: :ok, value: 42}} = Task.await(evaluation)
    info_result = if is_nil(yielded), do: Task.await(info), else: elem(yielded, 1)

    assert is_nil(yielded)
    assert {:ok, %{lifecycle: :open, evaluation_count: 1}} = info_result
  end

  @tag :tmp_dir
  test "construction exceptions clean owners acquired before the failure", %{tmp_dir: directory} do
    seed_trace(directory, "seed")
    parent = self()

    for stage <- [:after_snapshot, :after_session_trace] do
      starter =
        Task.async(fn ->
          start_log_session({:directory, directory}, {:directory, directory},
            builder_fault_hook: fn
              ^stage, resources ->
                send(parent, {:construction_fault, stage, resources, self()})

                receive do
                  :raise -> raise "injected construction failure"
                end

              _other_stage, _resources ->
                :ok
            end
          )
        end)

      assert_receive {:construction_fault, ^stage, resources, builder}, 1_000
      snapshot_ref = Process.monitor(resources.snapshot.pid)

      trace_ref =
        if session_trace = Map.get(resources, :session_trace) do
          Process.monitor(session_trace.pid)
        end

      send(builder, :raise)
      assert {:error, :run_analysis_session_failed} = Task.await(starter)
      assert_receive {:DOWN, ^snapshot_ref, :process, _pid, :normal}

      if trace_ref do
        assert_receive {:DOWN, ^trace_ref, :process, _pid, :normal}
      end
    end
  end

  @tag :tmp_dir
  test "implicit-route saturation still persists the reserved dropped and terminal events", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, info} =
             start_log_session({:directory, directory}, {:directory, directory})

    on_exit(fn -> AnalysisSession.stop(session) end)

    source = "(doseq [x (range 0 800)] (tool/runtime-remaining {}))"
    assert {:ok, %{outcome: :continued}} = AnalysisSession.evaluate(session, source)
    assert {:ok, %{lifecycle: :closed}} = AnalysisSession.close(session)

    path = Path.join(directory, info.session_id <> ".jsonl")

    events =
      path
      |> File.stream!()
      |> Enum.map(fn line -> Jason.decode!(line) end)

    assert Enum.count(events, &(&1["type"] == "events-dropped")) == 1
    assert Enum.count(events, &(&1["type"] == "run-stopped")) == 1
    assert List.last(events)["type"] == "run-stopped"
    assert length(events) == PublicRunAnalysisProfile.limits().normal_event_count

    assert {:ok, trace} = TraceLog.new(source: {:file, path})

    assert {:ok, %{"truncated" => true}} =
             TraceLog.query(trace, :get_run, %{"run_id" => info.session_id})
  end

  @tag :tmp_dir
  test "unexpected session-owner death records an aborted terminal run", %{tmp_dir: directory} do
    seed_trace(directory, "seed")

    assert {:ok, session, info} =
             start_log_session({:directory, directory}, {:directory, directory})

    state = :sys.get_state(session.pid)
    trace_ref = Process.monitor(state.session_trace.pid)
    session_ref = Process.monitor(session.pid)

    Process.exit(session.pid, :kill)

    assert_receive {:DOWN, ^session_ref, :process, _pid, :killed}
    assert_receive {:DOWN, ^trace_ref, :process, _pid, :normal}, @lifecycle_timeout_ms

    path = Path.join(directory, info.session_id <> ".jsonl")
    assert {:ok, trace} = TraceLog.new(source: {:file, path})

    assert {:ok, %{"status" => "error", "terminal_reason" => "session_owner_failed"}} =
             TraceLog.query(trace, :get_run, %{"run_id" => info.session_id})
  end

  @tag :tmp_dir
  test "unexpected owner death preserves an authoritative unpersisted terminal reason", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, info} =
             start_log_session({:directory, directory}, {:directory, directory})

    state = :sys.get_state(session.pid)

    :sys.replace_state(state.run_state.pid, fn run_state ->
      %{run_state | evaluations: run_state.limits.subordinate_evaluations}
    end)

    assert {:ok, %{outcome: :limit_exceeded, error: %{reason: :subordinate_evaluations}}} =
             AnalysisSession.evaluate(session, "42")

    assert {:ok, %{lifecycle: :terminal_unpersisted}} = AnalysisSession.info(session)
    trace_ref = Process.monitor(state.session_trace.pid)
    Process.exit(session.pid, :kill)
    assert_receive {:DOWN, ^trace_ref, :process, _pid, :normal}, @lifecycle_timeout_ms

    path = Path.join(directory, info.session_id <> ".jsonl")
    assert {:ok, trace} = TraceLog.new(source: {:file, path})

    assert {:ok, %{"status" => "error", "terminal_reason" => "subordinate_evaluations"}} =
             TraceLog.query(trace, :get_run, %{"run_id" => info.session_id})
  end

  @tag :tmp_dir
  test "unexpected owner death releases runtime resources before persistence", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()

    hook = fn
      :before_write ->
        send(parent, {:persistence_started, self()})

        receive do
          :continue_persistence -> :ok
        end

      _stage ->
        :ok
    end

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory},
               persistence_fault_hook: hook
             )

    state = :sys.get_state(session.pid)
    runtime_ref = Process.monitor(state.run_state.pid)
    snapshot_ref = Process.monitor(state.snapshot.pid)
    trace_ref = Process.monitor(state.session_trace.pid)

    Process.exit(session.pid, :kill)
    assert_receive {:persistence_started, trace_pid}, @lifecycle_timeout_ms
    on_exit(fn -> send(trace_pid, :continue_persistence) end)

    assert_receive {:DOWN, ^runtime_ref, :process, _pid, :normal}
    assert_receive {:DOWN, ^snapshot_ref, :process, _pid, :normal}
    send(trace_pid, :continue_persistence)
    assert_receive {:DOWN, ^trace_ref, :process, _pid, :normal}, @lifecycle_timeout_ms
  end

  @tag :tmp_dir
  test "unexpected owner death persistence failure is a one-shot best-effort attempt", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()

    hook = fn
      :before_write ->
        send(parent, :unexpected_owner_persistence_attempted)
        {:error, :injected}

      _stage ->
        :ok
    end

    assert {:ok, session, info} =
             start_log_session({:directory, directory}, {:directory, directory},
               persistence_fault_hook: hook
             )

    state = :sys.get_state(session.pid)
    runtime_ref = Process.monitor(state.run_state.pid)
    snapshot_ref = Process.monitor(state.snapshot.pid)
    trace_ref = Process.monitor(state.session_trace.pid)

    Process.exit(session.pid, :kill)

    assert_receive :unexpected_owner_persistence_attempted, 5_000
    assert_receive {:DOWN, ^runtime_ref, :process, _pid, :normal}
    assert_receive {:DOWN, ^snapshot_ref, :process, _pid, :normal}
    assert_receive {:DOWN, ^trace_ref, :process, _pid, :normal}, @lifecycle_timeout_ms
    refute File.exists?(Path.join(directory, info.session_id <> ".jsonl"))
  end

  @tag :tmp_dir
  test "trace owner retains and closes runtime when session dies during resource handoff", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()

    cleanup_hook = fn ->
      send(parent, {:resource_cleanup_started, self()})

      receive do
        :continue_cleanup -> :ok
      end
    end

    persistence_hook = fn
      :before_write ->
        send(parent, {:handoff_persistence_started, self()})
        :ok

      _stage ->
        :ok
    end

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory},
               resource_cleanup_hook: cleanup_hook,
               persistence_fault_hook: persistence_hook
             )

    state = :sys.get_state(session.pid)
    runtime_ref = Process.monitor(state.run_state.pid)
    snapshot_ref = Process.monitor(state.snapshot.pid)
    session_ref = Process.monitor(session.pid)
    trace_ref = Process.monitor(state.session_trace.pid)

    closer = Task.async(fn -> AnalysisSession.close(session) end)
    assert_receive {:resource_cleanup_started, trace_pid}
    Process.exit(session.pid, :kill)
    assert_receive {:DOWN, ^session_ref, :process, _pid, :killed}
    send(trace_pid, :continue_cleanup)

    assert_receive {:DOWN, ^runtime_ref, :process, _pid, :normal}
    assert_receive {:DOWN, ^snapshot_ref, :process, _pid, :normal}
    assert_receive {:handoff_persistence_started, ^trace_pid}, @lifecycle_timeout_ms
    assert_receive {:DOWN, ^trace_ref, :process, _pid, :normal}, @lifecycle_timeout_ms
    assert {:error, :session_closed} = Task.await(closer)
  end

  @tag :tmp_dir
  test "runtime death during trace-owned cleanup still releases the snapshot", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()

    cleanup_hook = fn ->
      send(parent, {:runtime_cleanup_ready, self()})

      receive do
        :continue_runtime_cleanup -> :ok
      end
    end

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory},
               resource_cleanup_hook: cleanup_hook
             )

    on_exit(fn -> AnalysisSession.stop(session) end)
    state = :sys.get_state(session.pid)
    runtime_ref = Process.monitor(state.run_state.pid)
    snapshot_ref = Process.monitor(state.snapshot.pid)
    closer = Task.async(fn -> AnalysisSession.close(session) end)

    assert_receive {:runtime_cleanup_ready, trace_pid}
    Process.exit(state.run_state.pid, :kill)
    assert_receive {:DOWN, ^runtime_ref, :process, _pid, :killed}
    send(trace_pid, :continue_runtime_cleanup)

    assert_receive {:DOWN, ^snapshot_ref, :process, _pid, :normal}
    assert {:ok, %{lifecycle: :closed}} = Task.await(closer)
  end

  @tag :tmp_dir
  test "runtime death during idle resource handoff marks the open recorder failed", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()
    {:ok, cleanup_calls} = Agent.start_link(fn -> 0 end)

    cleanup_hook = fn ->
      Agent.get_and_update(cleanup_calls, fn
        0 ->
          send(parent, {:idle_cleanup_ready, self()})

          receive do
            :continue_idle_cleanup -> {:ok, 1}
          end

        count ->
          {:ok, count + 1}
      end)
    end

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory},
               resource_cleanup_hook: cleanup_hook
             )

    on_exit(fn -> AnalysisSession.stop(session) end)
    state = :sys.get_state(session.pid)

    cleanup = Task.async(fn -> SessionTrace.resources_closed(state.session_trace) end)
    assert_receive {:idle_cleanup_ready, trace_pid}
    Process.exit(state.run_state.pid, :kill)
    send(trace_pid, :continue_idle_cleanup)

    assert :ok = Task.await(cleanup)

    assert %{
             persistence: :backend_failed,
             terminal: %{outcome: :error, reason: :event_sink_error}
           } = SessionTrace.info(state.session_trace)
  end

  @tag :tmp_dir
  test "runtime failure before batch handoff rejects finalization without a retry batch", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory})

    state = :sys.get_state(session.pid)
    :erlang.suspend_process(session.pid)

    try do
      assert :ok = RunState.close(state.run_state)
      Process.exit(state.run_state.pid, :kill)

      assert %{persistence: :backend_failed, event_count: 0} =
               SessionTrace.info(state.session_trace)

      assert {:error, :event_sink_error} =
               SessionTrace.finalize(state.session_trace, :error, :event_sink_error, %{})

      assert %{persistence: :backend_failed, event_count: 0} =
               SessionTrace.info(state.session_trace)
    after
      :erlang.resume_process(session.pid)
      AnalysisSession.stop(session)
    end
  end

  @tag :tmp_dir
  test "runtime failure after batch handoff preserves the frozen retry batch", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")

    assert {:ok, session, info} =
             start_log_session({:directory, directory}, {:directory, directory})

    state = :sys.get_state(session.pid)
    :erlang.suspend_process(session.pid)

    try do
      assert :ok = RunState.close(state.run_state)
      assert :ok = SessionTrace.finalize(state.session_trace, :ok, :closed, %{})
      Process.exit(state.run_state.pid, :kill)

      assert %{
               persistence: :terminal_unpersisted,
               terminal: %{outcome: :ok, reason: :closed},
               event_count: event_count
             } = SessionTrace.info(state.session_trace)

      assert event_count > 0
      assert {:ok, %{persistence: :persisted}} = SessionTrace.persist(state.session_trace)
      assert File.regular?(Path.join(directory, info.session_id <> ".jsonl"))
    after
      :erlang.resume_process(session.pid)
      AnalysisSession.stop(session)
    end
  end

  @tag :tmp_dir
  test "trace death during cleanup leaves a live backend-failed session and no owners", %{
    tmp_dir: directory
  } do
    seed_trace(directory, "seed")
    parent = self()

    cleanup_hook = fn ->
      send(parent, {:trace_cleanup_ready, self()})

      receive do
        :never -> :ok
      end
    end

    assert {:ok, session, _info} =
             start_log_session({:directory, directory}, {:directory, directory},
               resource_cleanup_hook: cleanup_hook
             )

    on_exit(fn -> AnalysisSession.stop(session) end)
    state = :sys.get_state(session.pid)
    session_ref = Process.monitor(session.pid)
    runtime_ref = Process.monitor(state.run_state.pid)
    snapshot_ref = Process.monitor(state.snapshot.pid)
    trace_ref = Process.monitor(state.session_trace.pid)
    closer = Task.async(fn -> AnalysisSession.close(session) end)

    assert_receive {:trace_cleanup_ready, trace_pid}
    Process.exit(trace_pid, :kill)
    assert_receive {:DOWN, ^trace_ref, :process, _pid, :killed}
    assert_receive {:DOWN, ^runtime_ref, :process, _pid, :normal}
    assert_receive {:DOWN, ^snapshot_ref, :process, _pid, :normal}
    assert {:error, :session_closed} = Task.await(closer)
    refute_received {:DOWN, ^session_ref, :process, _pid, _reason}
    assert {:ok, %{lifecycle: :backend_failed}} = AnalysisSession.info(session)
  end

  # ex_dna:disable-for-next-line — boundary test keeps its trace fixture local and explicit
  defp seed_trace(directory, run_id) do
    path = Path.join(directory, run_id <> ".jsonl")
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)
    :ok = EventSink.emit(sink, "run-started", %{missions: %{}})
    :ok = EventSink.emit(sink, "run-stopped", %{outcome: :ok, reason: nil})
    :ok = TraceLog.append_jsonl(path, EventSink.events(sink))
    EventSink.stop(sink)
  end

  defp start_log_session({:directory, directory}, destination, opts \\ []) do
    AnalysisSessionBuilder.start(
      PublicRunAnalysisProfile.id(),
      %{"traces" => directory},
      destination,
      opts
    )
  end

  defp directory_identity(directory) do
    stat = File.stat!(directory)
    {stat.major_device, stat.minor_device, stat.inode}
  end

  defp exhaust_protocol_budget(session) do
    for _attempt <- 1..32 do
      assert {:ok, %{outcome: :continued}} =
               AnalysisSession.evaluate(session, "(tool/runtime-usage {\"bad\" true})")
    end

    assert {:ok,
            %{
              status: :error,
              outcome: :limit_exceeded,
              continuation_effect: :preserved,
              error: %{kind: :limit_exceeded, reason: :protocol_errors}
            }} =
             AnalysisSession.evaluate(session, "(tool/runtime-usage {\"bad\" true})")
  end

  defp await_process_message(pid, predicate) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_await_process_message(pid, predicate, deadline)
  end

  defp stop_run_state(run_state) do
    RunState.stop(run_state)
  catch
    :exit, _reason -> :ok
  end

  defp do_await_process_message(pid, predicate, deadline) do
    messages = Process.info(pid, :messages) |> elem(1)

    if Enum.any?(messages, predicate) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("expected process message was not queued")
      else
        receive do
        after
          1 -> do_await_process_message(pid, predicate, deadline)
        end
      end
    end
  end
end
