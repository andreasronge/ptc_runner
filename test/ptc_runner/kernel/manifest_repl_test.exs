defmodule PtcRunner.Kernel.ManifestReplTest do
  # The cases that set app env, poison a :persistent_term attestation key, or assert the VM-wide
  # set of provider owner processes live in ManifestReplGlobalStateTest.
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]
  import PtcRunner.TestSupport.ManifestReplFixtures
  import PtcRunner.TestSupport.TestHelpers, only: [long_running_body: 1]

  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.EventBudget
  alias PtcRunner.Kernel.LimitConfiguration
  alias PtcRunner.Kernel.LimitConfigurationDiagnostic
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ManifestRepl
  alias PtcRunner.Kernel.ManifestReplOpening
  alias PtcRunner.Kernel.ManifestReplPreparation
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.ReplSessionOwner
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.TraceLog

  @tag :tmp_dir
  test "manifest preparation seals retain their exact struct domain", %{tmp_dir: directory} do
    manifest = write_provider_free_application(directory, :normal)
    {:ok, runtime} = CommandRuntime.new(provider_application_mode: :host_owned)

    assert {:ok, preparation} = CommandAcquisition.prepare_repl(manifest, nil, runtime, true)
    assert ManifestReplPreparation.valid?(preparation)

    refute preparation
           |> Map.put(:__struct__, CommandPreparation)
           |> ManifestReplPreparation.valid?()

    assert :ok = ManifestReplPreparation.close(preparation)
  end

  @tag :tmp_dir
  test "interactive workflow and mission sessions default lifetime rows to host ceilings", %{
    tmp_dir: directory
  } do
    write_component(directory)
    manifest = Path.join(directory, "interactive-limits.json")
    host = Path.join(directory, "interactive-limits-host.json")

    document =
      :normal
      |> manifest_document(%{})
      |> Map.put("missions", %{"review" => %{}})

    File.write!(manifest, Jason.encode!(document))

    File.write!(
      host,
      Jason.encode!(%{
        "install" => %{},
        "limits" => %{
          "run_duration_ms" => 120_000,
          "subordinate_evaluations" => 300
        }
      })
    )

    for mission <- [nil, "review"] do
      assert {:ok, session} =
               ManifestRepl.open(manifest, host,
                 input_mode: :interactive,
                 interactive_loop: true,
                 mission: mission,
                 terminal_attached: true
               )

      limits = owned_limits(session)
      assert limits.run_duration_ms == 120_000
      assert limits.subordinate_evaluations == 300
      assert limits.evaluation_timeout_ms == Limits.defaults().evaluation_timeout_ms
      assert %{remaining_ms: remaining} = ReplSession.usage(session)
      assert remaining in 1..120_000
      assert {:ok, _events} = ReplSession.close(session)
    end
  end

  @tag :tmp_dir
  test "explicit lifetime values win and non-interactive sessions keep ordinary defaults", %{
    tmp_dir: directory
  } do
    write_component(directory)
    manifest = Path.join(directory, "explicit-limits.json")
    host = Path.join(directory, "explicit-limits-host.json")

    document =
      :normal
      |> manifest_document(%{})
      |> Map.put("limits", %{
        "normal_event_bytes" => 8_000_000,
        "normal_event_count" => 300,
        "run_duration_ms" => 60_000,
        "subordinate_evaluations" => 7
      })

    File.write!(manifest, Jason.encode!(document))

    File.write!(
      host,
      Jason.encode!(%{
        "install" => %{},
        "limits" => %{
          "run_duration_ms" => 120_000,
          "subordinate_evaluations" => 300
        }
      })
    )

    assert {:ok, interactive} =
             ManifestRepl.open(manifest, host,
               input_mode: :interactive,
               interactive_loop: true,
               terminal_attached: true
             )

    assert %{
             normal_event_bytes: 8_000_000,
             normal_event_count: 300,
             run_duration_ms: 60_000,
             subordinate_evaluations: 7
           } = owned_limits(interactive)

    assert {:ok, _events} = ReplSession.close(interactive)

    plain_manifest = Path.join(directory, "ordinary-limits.json")
    File.write!(plain_manifest, Jason.encode!(manifest_document(:normal, %{})))

    assert {:ok, noninteractive} =
             ManifestRepl.open(plain_manifest, host,
               input_mode: :eval,
               interactive_loop: false,
               terminal_attached: true
             )

    defaults = Limits.defaults()

    assert %{run_duration_ms: run_duration_ms, subordinate_evaluations: evaluations} =
             owned_limits(noninteractive)

    assert run_duration_ms == defaults.run_duration_ms
    assert evaluations == defaults.subordinate_evaluations
    assert {:ok, _events} = ReplSession.close(noninteractive)
  end

  @tag :tmp_dir
  test "a private interactive session retains canonical events beyond 128 forms", %{
    tmp_dir: directory
  } do
    manifest = write_provider_free_application(directory, :private)

    assert {:ok, session} =
             ManifestRepl.open(manifest, nil,
               input_mode: :interactive,
               interactive_loop: true,
               private_terminal: true,
               terminal_attached: true
             )

    installed = Limits.installed_defaults()
    limits = owned_limits(session)
    assert limits.normal_event_count == installed.normal_event_count
    assert limits.normal_event_bytes == installed.normal_event_bytes

    session =
      Enum.reduce(1..140, session, fn value, current ->
        assert {:ok, %{return: ^value}, next} =
                 ReplSession.eval(current, Integer.to_string(value))

        next
      end)

    assert {:ok, events} = ReplSession.close(session)
    assert List.last(events).type == "run-stopped"
    refute Enum.any?(events, &(&1.type == "events-dropped"))
  end

  @tag :tmp_dir
  test "opening failure projects the exact public failure envelope", %{tmp_dir: directory} do
    write_component(directory)
    manifest = Path.join(directory, "opening-failure.json")

    document =
      :normal
      |> manifest_document(%{})
      |> Map.put("limits", %{"normal_event_bytes" => 1})

    File.write!(manifest, Jason.encode!(document))

    assert {:error, failure} =
             ManifestRepl.open(manifest, nil,
               input_mode: :interactive,
               terminal_attached: true
             )

    assert %{
             code: :limit_configuration_invalid,
             diagnostic: %CommandDiagnostic{code: :limit_configuration_invalid},
             provider_activity: false
           } = failure

    assert Enum.sort(Map.keys(failure)) == [:code, :diagnostic, :provider_activity]
  end

  @tag :tmp_dir
  test "manifest REPL rejects impossible effective normal trace budgets before opening", %{
    tmp_dir: directory
  } do
    write_component(directory)
    manifest = Path.join(directory, "invalid-trace-budget.json")
    payload_bytes = EventBudget.minimum_normal_payload_bytes()
    {:ok, base_limits} = Limits.new(event_payload_bytes: payload_bytes)
    required_bytes = LimitConfiguration.required_normal_event_bytes(base_limits)

    document =
      :normal
      |> manifest_document(%{})
      |> Map.put("limits", %{
        "event_payload_bytes" => payload_bytes,
        "normal_event_bytes" => required_bytes - 1,
        "normal_event_count" => 3
      })

    File.write!(manifest, Jason.encode!(document))
    {:ok, runtime} = CommandRuntime.new(provider_application_mode: :host_owned)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             CommandAcquisition.prepare_repl(manifest, nil, runtime, true)

    assert diagnostic.phase == :application
    assert diagnostic.code == :limit_configuration_invalid
    assert diagnostic.provider_activity == false

    diagnostic_message = diagnostic.message

    assert {:ok, ^diagnostic_message} =
             LimitConfigurationDiagnostic.message(
               required_bytes - 1,
               required_bytes,
               payload_bytes
             )

    for count <- [1, 2] do
      File.write!(
        manifest,
        Jason.encode!(Map.put(document, "limits", %{"normal_event_count" => count}))
      )

      assert {:error, %CommandDiagnostic{} = count_diagnostic} =
               CommandAcquisition.prepare_repl(manifest, nil, runtime, true)

      assert count_diagnostic.code == :schema_violation
      assert CommandDiagnostic.to_map(count_diagnostic)["path"] == "/limits/normal_event_count"
    end
  end

  @tag :tmp_dir
  test "manifest REPL rejects a private trace budget that cannot retain its terminal event", %{
    tmp_dir: directory
  } do
    write_component(directory)
    manifest = Path.join(directory, "invalid-private-trace-budget.json")
    payload_bytes = EventBudget.minimum_normal_payload_bytes()
    {:ok, base_limits} = Limits.new(event_payload_bytes: payload_bytes)
    required_bytes = LimitConfiguration.required_private_event_bytes(base_limits)

    document =
      :private
      |> manifest_document(%{})
      |> Map.put("limits", %{
        "event_payload_bytes" => payload_bytes,
        "normal_event_bytes" => required_bytes - 1
      })

    File.write!(manifest, Jason.encode!(document))
    {:ok, runtime} = CommandRuntime.new(provider_application_mode: :host_owned)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             CommandAcquisition.prepare_repl(manifest, nil, runtime, true)

    assert diagnostic.phase == :application
    assert diagnostic.code == :limit_configuration_invalid

    diagnostic_message = diagnostic.message

    assert {:ok, ^diagnostic_message} =
             LimitConfigurationDiagnostic.message(
               required_bytes - 1,
               required_bytes,
               payload_bytes
             )
  end

  @tag :tmp_dir
  test "stale capability requirements have the same actionable REPL diagnostic with or without providers",
       %{tmp_dir: directory} do
    provider_free = write_provider_free_application(directory, :normal)

    File.write!(
      Path.join(directory, "main.clj"),
      ~S|(ns app) (defn run [input] (tool/history.list-runs {"limit" 1}))|
    )

    {provider_backed, host} = write_stale_trace_application(directory)

    for {manifest, host_path, provider_activity} <- [
          {provider_free, nil, false},
          {provider_backed, host, true}
        ] do
      assert {:error,
              %{code: :capability_requirement_missing, provider_activity: ^provider_activity}} =
               ManifestRepl.open(manifest, host_path,
                 input_mode: :interactive,
                 terminal_attached: true
               )
    end
  end

  test "manifest opening status redacts retained state" do
    status = %{state: %{private_input: "secret"}, message: {:work, "secret"}, log: ["secret"]}

    redacted = ManifestReplOpening.format_status(status)

    refute inspect(redacted) =~ "secret"
    assert redacted.state == :redacted
  end

  @tag :tmp_dir
  test "composed workflow and mission sessions return reachable definition source", %{
    tmp_dir: directory
  } do
    {manifest, _host} = write_provider_free_mission_application(directory)

    assert {:ok, workflow} =
             ManifestRepl.open(manifest, nil,
               input_mode: :interactive,
               terminal_attached: true
             )

    assert {:ok, workflow_source, workflow} =
             ReplSession.eval(workflow, "(source app/run)")

    assert workflow_source.return == nil
    assert Enum.join(workflow_source.prints, "\n") =~ "(defn run"

    assert {:ok, helper_source, workflow} =
             ReplSession.eval(workflow, "(source app/offset)")

    assert Enum.join(helper_source.prints, "\n") =~ "(defn- offset"

    assert {:ok, dead_source, workflow} =
             ReplSession.eval(workflow, "(source app/dead-helper)")

    assert Enum.join(dead_source.prints, "\n") =~ ~s(No source available for "app/dead-helper")

    assert {:ok, unattached, workflow} =
             ReplSession.eval(workflow, "(source review/score)")

    assert Enum.join(unattached.prints, "\n") =~ ~s(No source available for "review/score")

    assert {:ok, _events} = ReplSession.close(workflow)

    assert {:ok, mission} =
             ManifestRepl.open(manifest, nil,
               mission: "review",
               input_mode: :interactive,
               terminal_attached: true
             )

    assert {:ok, mission_source, mission} =
             ReplSession.eval(mission, "(source review/score)")

    assert mission_source.return == nil
    assert Enum.join(mission_source.prints, "\n") =~ "(defn score"

    assert {:ok, workflow_unattached, mission} =
             ReplSession.eval(mission, "(source app/run)")

    assert Enum.join(workflow_unattached.prints, "\n") =~
             ~s(No source available for "app/run")

    assert {:ok, _events} = ReplSession.close(mission)
  end

  @tag :tmp_dir
  test "an authorized private provider-free session preserves private trace permissions", %{
    tmp_dir: directory
  } do
    manifest = write_provider_free_application(directory, :private)
    trace_path = Path.join(directory, "session.private.jsonl")

    assert {:ok, session} =
             ManifestRepl.open(manifest, nil,
               input_mode: :interactive,
               private_terminal: true,
               terminal_attached: true,
               trace_path: trace_path
             )

    assert {:ok, %{return: 42}, session} = ReplSession.eval(session, "(+ 40 2)")
    assert {:ok, _events} = ReplSession.close(session)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(trace_path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert {:ok, _trace} = TraceLog.new(source: {:private_file, trace_path})
  end

  @tag :tmp_dir
  test "mission mode owns its context and preserves strict mission continuation", %{
    tmp_dir: directory
  } do
    marker = Path.join(directory, "mission-provider-lifecycle")
    {manifest, host} = write_mcp_mission_application(directory, marker)

    assert {:ok, session} =
             ManifestRepl.open(manifest, host,
               mission: "review",
               input_mode: :interactive,
               terminal_attached: true
             )

    assert %{
             kind: :mission,
             mission: "review",
             component_ids: ["review"],
             direct_provider_aliases: ["workspace"]
           } = ReplSession.mode_info(session)

    assert {:ok, %{mission: "review", model_context: rendered, model_context_hash: hash}} =
             ReplSession.mission_context(session)

    assert is_binary(rendered)
    assert byte_size(rendered) > 0
    assert hash == :crypto.hash(:sha256, rendered) |> Base.encode16(case: :lower)

    assert {:ok, %{return: %{"return" => 1, "fail" => 2}}, session} =
             ReplSession.eval(session, ~S|{"return" 1 "fail" 2}|)

    assert {:ok, _step, session} = ReplSession.eval(session, "(def retained 40)")
    assert {:error, _step, session} = ReplSession.eval(session, "missing")

    assert {:error, %{fail: %{reason: :public_projection_collision}}, session} =
             ReplSession.eval(session, ~S|{:zzzz_collision 1 "zzzz_collision" 2}|)

    assert {:ok, %{return: 42}, session} = ReplSession.eval(session, "(+ retained 2)")
    assert {:ok, _events} = ReplSession.close(session)
    assert_eventually(fn -> "session-closed" in lifecycle(marker) end)
  end

  # A mission form is bounded by `evaluation_timeout_ms` too, and the evaluator
  # hands back only the milliseconds it had left. The interactive path must name
  # the ceiling for a mission session exactly as it does for a workflow one.
  @tag :tmp_dir
  test "a mission form stopped by the evaluation ceiling names the limit", %{tmp_dir: directory} do
    manifest = write_provider_free_application(directory, :normal)
    document = manifest |> File.read!() |> Jason.decode!()

    document =
      document
      |> Map.put("limits", %{"evaluation_timeout_ms" => 200})
      |> Map.put("missions", %{
        "review" => %{"components" => [], "data" => %{}, "providers" => []}
      })

    File.write!(manifest, Jason.encode!(document))

    assert {:ok, session} =
             ManifestRepl.open(manifest, nil,
               mission: "review",
               input_mode: :interactive,
               terminal_attached: true
             )

    assert {:error, %{fail: %{reason: :timeout, message: message}}, session} =
             ReplSession.eval(session, long_running_body(4))

    assert RuntimeLimitDiagnostic.timeout_message?(message)
    assert message =~ "evaluation_timeout_ms limit 200 ms was exceeded during execution"
    assert message =~ "raise limits.evaluation_timeout_ms in the manifest"

    assert {:ok, _events} = ReplSession.close(session)
  end

  @tag :tmp_dir
  test "a mission form that consumes the absolute deadline terminalizes synchronously", %{
    tmp_dir: directory
  } do
    manifest = write_provider_free_application(directory, :normal)
    document = manifest |> File.read!() |> Jason.decode!()

    document =
      document
      |> Map.put("limits", %{
        "run_duration_ms" => 200,
        "evaluation_timeout_ms" => 5_000
      })
      |> Map.put("missions", %{
        "review" => %{"components" => [], "data" => %{}, "providers" => []}
      })

    File.write!(manifest, Jason.encode!(document))

    assert {:ok, session} =
             ManifestRepl.open(manifest, nil,
               mission: "review",
               input_mode: :eval,
               interactive_loop: false,
               terminal_attached: true
             )

    [{_, {owner, _token}}] = :ets.lookup(session.access, session.id)

    :sys.replace_state(owner, fn state ->
      Process.cancel_timer(state.deadline_timer)
      %{state | deadline_timer: nil, deadline_token: nil}
    end)

    assert {:error, %{fail: %{reason: :limit_exceeded, message: message}}, session} =
             ReplSession.eval(session, long_running_body(4))

    assert message =~ "run_duration_ms limit 200 ms was exceeded"
    assert ReplSession.terminal?(session)
    assert {:ok, events} = ReplSession.close(session)

    assert [%{data: %{reason: :deadline_expired}}] =
             Enum.filter(events, &(&1.type == "limit-exceeded"))

    assert List.last(events).data.reason == :deadline_expired
  end

  @tag :tmp_dir
  test "mission mode rejects oversized returned and failed values without committing", %{
    tmp_dir: directory
  } do
    manifest = write_provider_free_application(directory, :normal)
    document = manifest |> File.read!() |> Jason.decode!()

    document =
      document
      |> Map.put("limits", %{"terminal_result_bytes" => 256})
      |> Map.put("missions", %{
        "review" => %{
          "components" => [],
          "data" => %{},
          "providers" => []
        }
      })

    File.write!(manifest, Jason.encode!(document))

    assert {:ok, session} =
             ManifestRepl.open(manifest, nil,
               mission: "review",
               input_mode: :interactive,
               terminal_attached: true
             )

    oversized = inspect(String.duplicate("x", 2_048))

    assert {:ok, _step, session} = ReplSession.eval(session, "(def retained 40)")

    assert {:error, %{fail: %{reason: :result_exceeded}}, session} =
             ReplSession.eval(session, "(do (def leaked 1) (return #{oversized}))")

    assert {:error, _step, session} = ReplSession.eval(session, "leaked")
    assert {:ok, %{return: 42}, session} = ReplSession.eval(session, "(+ retained 2)")

    assert {:error, %{fail: %{reason: :result_exceeded}}, session} =
             ReplSession.eval(session, "(fail #{oversized})")

    assert {:ok, _events} = ReplSession.close(session)
  end

  @tag :tmp_dir
  test "mission mode charges immediate scalar values to the terminal result limit", %{
    tmp_dir: directory
  } do
    manifest = write_provider_free_application(directory, :normal)
    document = manifest |> File.read!() |> Jason.decode!()

    document =
      document
      |> Map.put("limits", %{"terminal_result_bytes" => 1})
      |> Map.put("missions", %{"review" => %{}})

    File.write!(manifest, Jason.encode!(document))

    assert {:ok, session} =
             ManifestRepl.open(manifest, nil,
               mission: "review",
               input_mode: :interactive,
               terminal_attached: true
             )

    assert {:error, %{fail: %{reason: :result_exceeded}}, session} =
             ReplSession.eval(session, "42")

    assert {:ok, _events} = ReplSession.close(session)
  end

  @tag :tmp_dir
  test "killing an adopted session owner also terminates its run state", %{tmp_dir: directory} do
    manifest = write_provider_free_application(directory, :normal)
    trace_path = Path.join(directory, "killed-owner.jsonl")

    assert {:ok, session} =
             ManifestRepl.open(manifest, nil,
               input_mode: :interactive,
               terminal_attached: true,
               trace_path: trace_path
             )

    [{id, {owner, token}}] = :ets.lookup(session.access, session.id)
    assert {:ok, _config, run_state} = ReplSessionOwner.resources(owner, token)
    owner_ref = Process.monitor(owner)
    run_state_ref = Process.monitor(run_state.pid)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    assert_receive {:DOWN, ^run_state_ref, :process, _pid, :killed}, 5_000
    assert {:error, :session_closed} = ReplSession.close(session)
    assert :ets.lookup(session.access, id) == []

    assert_eventually(fn ->
      File.exists?(trace_path) and File.read!(trace_path) =~ "session_owner_failed"
    end)
  end

  @tag :tmp_dir
  test "caller death finalizes once and closes the retained provider session", %{
    tmp_dir: directory
  } do
    marker = Path.join(directory, "provider-lifecycle")
    trace_path = Path.join(directory, "caller-death.jsonl")
    {manifest, host} = write_mcp_application(directory, marker, 20_000, "mark-close")
    parent = self()

    {caller, caller_ref} =
      spawn_monitor(fn ->
        result =
          ManifestRepl.open(manifest, host,
            input_mode: :interactive,
            terminal_attached: true,
            trace_path: trace_path
          )

        owner =
          case result do
            {:ok, session} ->
              [{_, {owner, _token}}] = :ets.lookup(session.access, session.id)
              owner

            _failure ->
              nil
          end

        send(parent, {:manifest_repl_opened, self(), owner, result})

        receive do
          :close -> :ok
        end
      end)

    assert_receive {:manifest_repl_opened, ^caller, owner, {:ok, %ReplSession{}}}, 10_000
    owner_ref = Process.monitor(owner)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 5_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 5_000

    assert_eventually(fn ->
      lifecycle(marker) |> Enum.count(&(&1 == "session-closed")) == 1
    end)

    assert_eventually(fn -> File.exists?(trace_path) end)
    assert File.read!(trace_path) =~ "session_owner_failed"
  end

  # `run_duration_ms` has to outlive MCP stdio handshake (250 ms expired
  # during `open/3`), then this waits the remaining budget so eval sees a
  # closed deadline. That is a multi-second wait on purpose — `mix nightly`.
  @tag :tmp_dir
  @tag :nightly
  test "a manifest session deadline cancels work and closes its provider once", %{
    tmp_dir: directory
  } do
    marker = Path.join(directory, "deadline-provider-lifecycle")
    trace_path = Path.join(directory, "deadline.jsonl")

    {manifest, host} =
      write_mcp_application(directory, marker, 5_000, "mark-close")

    assert {:ok, session} =
             ManifestRepl.open(manifest, host,
               input_mode: :interactive,
               terminal_attached: true,
               trace_path: trace_path
             )

    deadline_elapsed = make_ref()
    Process.send_after(self(), deadline_elapsed, 5_000)
    assert_receive ^deadline_elapsed, 6_000

    assert {:error, %{fail: %{reason: reason}}, session} =
             ReplSession.eval(session, "42")

    assert reason == :limit_exceeded
    assert {:ok, _events} = ReplSession.close(session)

    assert_eventually(fn ->
      lifecycle(marker) |> Enum.count(&(&1 == "session-closed")) == 1
    end)

    assert File.read!(trace_path) =~ "deadline_expired"
  end

  defp write_provider_free_application(directory, policy) do
    write_component(directory)
    manifest = Path.join(directory, "provider-free-#{policy}.json")
    File.write!(manifest, Jason.encode!(manifest_document(policy, %{})))
    manifest
  end

  defp write_provider_free_mission_application(directory) do
    File.write!(
      Path.join(directory, "main.clj"),
      """
      (ns app)

      (defn- offset [value] (+ value 2))
      (defn- dead-helper [value] value)
      (defn run [input] (return (offset (get input "value" 40))))
      """
    )

    File.write!(
      Path.join(directory, "review.clj"),
      """
      (ns review)

      (defn score [input] (+ (get input "value" 0) 1))
      """
    )

    manifest = Path.join(directory, "provider-free-source.json")

    document =
      manifest_document(:normal, %{})
      |> Map.put("missions", %{
        "review" => %{
          "components" => [%{"id" => "review", "path" => "review.clj"}],
          "data" => %{}
        }
      })

    File.write!(manifest, Jason.encode!(document))
    {manifest, nil}
  end

  defp write_mcp_mission_application(directory, marker) do
    {manifest, host} = write_mcp_application(directory, marker, 20_000, "mark-close")
    File.write!(Path.join(directory, "review.clj"), "(ns review)")

    document =
      manifest
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("missions", %{
        "review" => %{
          "components" => [%{"id" => "review", "path" => "review.clj"}],
          "data" => %{"answer" => 40},
          "providers" => ["workspace"]
        }
      })

    File.write!(manifest, Jason.encode!(document))
    {manifest, host}
  end

  defp write_stale_trace_application(directory) do
    trace_directory = Path.join(directory, "traces")
    File.mkdir_p!(trace_directory)

    File.write!(
      Path.join(directory, "legacy.clj"),
      ~S|(ns legacy) (defn inspect [input] (tool/history.list-runs {"limit" 1}))|
    )

    manifest = Path.join(directory, "stale-trace.json")
    host = Path.join(directory, "stale-trace-host.json")

    document =
      manifest_document(:normal, %{
        "workflow" => [],
        "mission" => [%{"name" => "history", "config" => %{}}]
      })
      |> Map.put("missions", %{
        "default" => %{
          "components" => [%{"id" => "legacy", "path" => "legacy.clj"}],
          "data" => %{},
          "providers" => ["history"]
        }
      })

    File.write!(manifest, Jason.encode!(document))

    File.write!(
      host,
      Jason.encode!(%{
        "install" => %{
          "history" => %{
            "source" => "ptc_trace_snapshot",
            "installation_revision" => "history-v1",
            "directory" => trace_directory,
            "ceilings" => %{
              "max_source_bytes" => 2_000_000,
              "max_result_bytes" => 250_000
            }
          }
        }
      })
    )

    {manifest, host}
  end

  defp lifecycle(marker) do
    case File.read(marker) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp owned_limits(%ReplSession{access: access, id: id}) do
    [{^id, {owner, token}}] = :ets.lookup(access, id)
    assert {:ok, config, _state} = ReplSessionOwner.resources(owner, token)
    config.limits
  end
end
