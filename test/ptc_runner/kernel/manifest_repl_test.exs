defmodule PtcRunner.Kernel.ManifestReplTest do
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]
  import PtcRunner.TestSupport.TestHelpers, only: [long_running_body: 1]

  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.HostRuntimePayload
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ManifestRepl
  alias PtcRunner.Kernel.ManifestReplOpening
  alias PtcRunner.Kernel.ManifestReplPreparation
  alias PtcRunner.Kernel.OwnerFailure
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.ReplSessionOwner
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.TraceLog

  @stdio_root Path.expand("../../..", __DIR__)
  @stdio_fixture Path.expand("../../support/mcp_stdio_source_fixture.sh", __DIR__)

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
  test "runtime-service sealing failure closes the prepared activity owner", %{
    tmp_dir: directory
  } do
    {manifest, host} =
      write_mcp_application(
        directory,
        Path.join(directory, "unused-runtime-service"),
        20_000,
        "mark-close"
      )

    {:ok, runtime} = CommandRuntime.new(provider_application_mode: :host_owned)
    storage_key = {PtcRunner.Kernel.Attestation, HostRuntimePayload}
    previous_key = :persistent_term.get(storage_key, :missing)

    on_exit(fn ->
      case previous_key do
        :missing -> :persistent_term.erase(storage_key)
        key -> :persistent_term.put(storage_key, key)
      end
    end)

    :persistent_term.put(storage_key, :invalid_hmac_key)
    owners_before = provider_activity_owners()

    assert {:error, _reason} = CommandAcquisition.prepare_repl(manifest, host, runtime, true)

    assert MapSet.difference(provider_activity_owners(), owners_before) == MapSet.new()
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

    assert %{code: code, provider_activity: false} = failure
    assert is_atom(code)
    assert Enum.sort(Map.keys(failure)) == [:code, :provider_activity]
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
  test "private manifest terminal policy rejects every unattended mode before active work", %{
    tmp_dir: directory
  } do
    configure_host_llm()
    {manifest, host} = write_llm_application(directory, :private)
    {:ok, runtime} = CommandRuntime.new(provider_application_mode: :host_owned)

    cases =
      [
        {:private_terminal_required,
         [input_mode: :interactive, private_terminal: false, terminal_attached: true]},
        {:interactive_terminal_required,
         [input_mode: :interactive, private_terminal: true, terminal_attached: false]}
      ] ++
        Enum.map([:load, :eval, :script, :stdin, :jsonl], fn mode ->
          {:private_manifest_interactive_only,
           [input_mode: mode, private_terminal: true, terminal_attached: true]}
        end)

    for {code, opts} <- cases do
      assert {:error, %{code: ^code, provider_activity: false}} =
               ManifestRepl.open(manifest, host, Keyword.put(opts, :runtime, runtime))
    end

    refute_received {:host_llm_ensure_ready, _pid}
    refute_received {:host_llm_request, _model, _request}
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
  test "a provider-free mission leaves an unrelated workflow provider inert", %{
    tmp_dir: directory
  } do
    {manifest, host} = write_llm_mission_application(directory, :workflow)
    configure_host_llm()
    parent = self()

    {:ok, runtime} =
      CommandRuntime.new(
        provider_application_mode: :host_owned,
        environment_setup: fn -> send(parent, :unrelated_environment_setup) && :ok end
      )

    assert {:ok, session} =
             ManifestRepl.open(manifest, host,
               mission: "review",
               runtime: runtime,
               input_mode: :interactive,
               terminal_attached: true
             )

    assert %{kind: :mission, direct_provider_aliases: []} = ReplSession.mode_info(session)
    assert {:ok, %{return: 42}, session} = ReplSession.eval(session, "(+ data/answer 2)")
    assert {:ok, _events} = ReplSession.close(session)
    refute_received :unrelated_environment_setup
    refute_received {:host_llm_ensure_ready, _worker}
    refute_received {:host_llm_request, _model, _request}
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

  @tag :tmp_dir
  test "an active opening worker death returns a marked failure after cleanup", %{
    tmp_dir: directory
  } do
    gate = make_ref()
    configure_host_llm(host_llm_test_ready_gate: gate)
    {manifest, host} = write_llm_application(directory, :normal)
    trace_path = Path.join(directory, "worker-death.jsonl")
    {:ok, runtime} = CommandRuntime.new(provider_application_mode: :host_owned)
    parent = self()

    opener =
      spawn(fn ->
        send(
          parent,
          {:manifest_repl_result,
           ManifestRepl.open(manifest, host,
             runtime: runtime,
             input_mode: :interactive,
             terminal_attached: true,
             trace_path: trace_path
           )}
        )
      end)

    assert_receive {:host_llm_ensure_ready, worker}, 5_000
    Process.exit(worker, :kill)

    assert_receive {:manifest_repl_result, {:error, failure}}, 5_000

    assert %{provider_activity: true, code: code} = failure
    assert is_atom(code)
    assert Enum.sort(Map.keys(failure)) == [:code, :provider_activity]
    refute Process.alive?(opener)

    assert_eventually(fn -> File.exists?(trace_path) end)
    assert File.read!(trace_path) == ""
  end

  @tag :tmp_dir
  test "the opening owner seals marked failure evidence before teardown", %{
    tmp_dir: directory
  } do
    gate = make_ref()
    configure_host_llm(host_llm_test_ready_gate: gate)
    {manifest, host} = write_llm_application(directory, :normal)
    {:ok, runtime} = CommandRuntime.new(provider_application_mode: :host_owned)
    assert {:ok, preparation} = CommandAcquisition.prepare_repl(manifest, host, runtime, true)
    assert {:ok, authority} = PublicationAuthority.new([])
    assert {:ok, opening} = ManifestReplOpening.start(preparation, authority, nil, self())
    opening_ref = Process.monitor(ManifestReplOpening.pid(opening))

    assert_receive {:host_llm_ensure_ready, worker}, 5_000
    Process.exit(worker, :kill)

    assert {:error, failure} = ManifestReplOpening.await(opening)
    assert_receive {:DOWN, ^opening_ref, :process, _pid, :normal}, 5_000

    assert {:ok, %CommandDiagnostic{provider_activity: true}, true, :incomplete} =
             OwnerFailure.evidence(failure)
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

  defp configure_host_llm(extra \\ []) do
    keys = [:llm_adapter, :host_llm_test_owner, :host_llm_test_ready_gate]
    previous = Map.new(keys, &{&1, Application.get_env(:ptc_runner, &1, :unset)})

    Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.TestSupport.HostLLMAdapter)
    Application.put_env(:ptc_runner, :host_llm_test_owner, self())

    Enum.each(extra, fn {key, value} -> Application.put_env(:ptc_runner, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, :unset} -> Application.delete_env(:ptc_runner, key)
        {key, value} -> Application.put_env(:ptc_runner, key, value)
      end)
    end)
  end

  defp write_provider_free_application(directory, policy) do
    write_component(directory)
    manifest = Path.join(directory, "provider-free-#{policy}.json")
    File.write!(manifest, Jason.encode!(manifest_document(policy, %{})))
    manifest
  end

  defp write_llm_application(directory, policy) do
    write_component(directory)
    manifest = Path.join(directory, "llm-#{policy}.json")
    host = Path.join(directory, "llm-host.json")

    providers = %{
      "workflow" => [%{"name" => "model", "config" => %{}}],
      "mission" => []
    }

    File.write!(manifest, Jason.encode!(manifest_document(policy, providers)))

    File.write!(
      host,
      Jason.encode!(%{
        "credentials" => %{"key" => %{"literal" => "not-a-real-secret"}},
        "install" => %{
          "model" => %{
            "source" => "llm",
            "installation_revision" => "manifest-repl-test-v1",
            "model" => "openrouter:test/model",
            "credential" => "key"
          }
        }
      })
    )

    {manifest, host}
  end

  defp write_llm_mission_application(directory, destination) do
    write_component(directory)
    File.write!(Path.join(directory, "review.clj"), "(ns review)")
    manifest = Path.join(directory, "llm-mission-#{destination}.json")
    host = Path.join(directory, "llm-mission-host.json")

    providers = %{
      "workflow" =>
        if(destination == :workflow, do: [%{"name" => "model", "config" => %{}}], else: []),
      "mission" =>
        if(destination == :mission, do: [%{"name" => "model", "config" => %{}}], else: [])
    }

    mission_providers = if destination == :mission, do: ["model"], else: []

    document =
      manifest_document(:normal, providers)
      |> Map.put("missions", %{
        "review" => %{
          "components" => [%{"id" => "review", "path" => "review.clj"}],
          "data" => %{"answer" => 40},
          "providers" => mission_providers
        }
      })

    File.write!(manifest, Jason.encode!(document))

    File.write!(
      host,
      Jason.encode!(%{
        "credentials" => %{"key" => %{"env" => "UNRELATED_REPL_KEY"}},
        "install" => %{
          "model" => %{
            "source" => "llm",
            "installation_revision" => "manifest-mission-repl-test-v1",
            "model" => "openrouter:test/model",
            "credential" => "key"
          }
        }
      })
    )

    {manifest, host}
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

  defp write_mcp_application(directory, marker, run_duration_ms, mode) do
    write_component(directory)
    manifest = Path.join(directory, "mcp.json")
    host = Path.join(directory, "mcp-host.json")

    File.write!(
      manifest,
      Jason.encode!(
        manifest_document(:normal, %{
          "workflow" => [],
          "mission" => [
            %{"name" => "workspace", "config" => %{"allow" => ["workspace.structured"]}}
          ]
        })
        |> Map.put("limits", %{
          "evaluation_timeout_ms" => 20_000,
          "run_duration_ms" => run_duration_ms
        })
      )
    )

    File.write!(
      host,
      Jason.encode!(%{
        "install" => %{
          "workspace" => %{
            "source" => "mcp",
            "installation_revision" => "manifest-repl-stdio-v1",
            "transport" => %{
              "type" => "stdio",
              "command" => System.find_executable("sh"),
              "cwd" => @stdio_root,
              "args" => [@stdio_fixture, marker, mode],
              "start_timeout_ms" => 5_000
            },
            "tools" => %{
              "structured" => %{
                "as" => "workspace.structured",
                "effect" => "write",
                "model_visible" => true
              }
            },
            "ceilings" => %{"timeout_ms" => 20_000}
          }
        }
      })
    )

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

  defp write_component(directory) do
    File.write!(Path.join(directory, "main.clj"), "(ns app) (defn run [input] (return input))")
  end

  defp manifest_document(policy, providers) do
    %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "providers" => providers,
      "input" => %{"value" => %{}},
      "events" => %{"policy" => Atom.to_string(policy)}
    }
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

  defp provider_activity_owners do
    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          Keyword.get(dictionary, :"$initial_call") ==
            {PtcRunner.Kernel.ProviderActivity, :init, 1}

        nil ->
          false
      end
    end)
    |> MapSet.new()
  end
end
