defmodule PtcRunner.Kernel.ManifestReplTest do
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.ManifestRepl
  alias PtcRunner.Kernel.ManifestReplOpening
  alias PtcRunner.Kernel.ManifestReplPreparation
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.ReplSessionOwner
  alias PtcRunner.Kernel.TraceLog

  @stdio_root Path.expand("../../..", __DIR__)
  @stdio_fixture Path.expand("../../support/mcp_stdio_source_fixture.sh", __DIR__)

  @tag :tmp_dir
  test "manifest preparation seals retain their exact struct domain", %{tmp_dir: directory} do
    manifest = write_provider_free_application(directory, :normal)
    {:ok, runtime} = CommandRuntime.new(provider_application_mode: :host_owned)

    assert {:ok, preparation} = CommandAcquisition.prepare_repl(manifest, nil, runtime)
    assert ManifestReplPreparation.valid?(preparation)

    refute preparation
           |> Map.put(:__struct__, CommandPreparation)
           |> ManifestReplPreparation.valid?()

    assert :ok = ManifestReplPreparation.close(preparation)
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

    assert_receive {:manifest_repl_result, {:error, %{provider_activity: true, code: code}}},
                   5_000

    assert is_atom(code)
    refute Process.alive?(opener)

    assert_eventually(fn -> File.exists?(trace_path) end)
    assert File.read!(trace_path) == ""
  end

  @tag :tmp_dir
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

    assert reason in [:limit_exceeded, :run_deadline_exceeded, :evaluation_timeout]
    assert {:ok, _events} = ReplSession.close(session)

    assert_eventually(fn ->
      lifecycle(marker) |> Enum.count(&(&1 == "session-closed")) == 1
    end)

    assert File.read!(trace_path) =~ "repl_evaluation_error"
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
end
