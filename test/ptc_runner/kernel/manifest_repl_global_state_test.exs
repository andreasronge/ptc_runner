defmodule PtcRunner.Kernel.ManifestReplGlobalStateTest do
  # async: false — these cases set :ptc_runner :llm_adapter app env, poison a :persistent_term
  # attestation key, or assert the VM-wide set of ProviderActivity owners (class D). The rest of
  # manifest REPL coverage is async in ManifestReplTest.
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]
  import PtcRunner.TestSupport.ManifestReplFixtures

  alias PtcRunner.Kernel.CommandAcquisition
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.HostRuntimePayload
  alias PtcRunner.Kernel.ManifestRepl
  alias PtcRunner.Kernel.ManifestReplOpening
  alias PtcRunner.Kernel.OwnerFailure
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.ReplSession

  @tag :tmp_dir
  test "workflow REPL keeps agent run-outcome terminal mission results as data", %{
    tmp_dir: directory
  } do
    configure_host_llm(
      host_llm_test_result:
        {:ok,
         %{
           content: nil,
           tool_calls: [
             %{id: "terminal", name: "run_ptc_lisp", args: %{"program" => "(return 42)"}}
           ],
           tokens: %{}
         }}
    )

    {manifest, host} = write_llm_application(directory, :normal)

    File.write!(
      Path.join(directory, "main.clj"),
      ~S|(ns app) (defn run [_input] (agent.core/run-outcome "Return 42" {"mission" "default" "model" "model" "max_turns" 1 "retain_programs" 2}))|
    )

    document = Jason.decode!(File.read!(manifest))

    document =
      document
      |> put_in(["workflow", "components"], [
        %{"library" => "agent.core"},
        %{"id" => "app", "path" => "main.clj", "dependencies" => ["agent.core"]}
      ])
      |> Map.put("missions", %{"default" => %{}})

    File.write!(manifest, Jason.encode!(document))

    assert {:ok, session} =
             ManifestRepl.open(manifest, host,
               input_mode: :eval,
               interactive_loop: false,
               terminal_attached: true
             )

    assert {:ok, result, session} = ReplSession.eval(session, "(app/run {})")
    assert result.return["status"] == "returned"
    assert result.return["value"] == 42

    assert result.return["programs"] == [
             %{
               :source => "(return 42)",
               "execution" => %{"outcome" => "returned"},
               "mission" => "default",
               "turn" => 1
             }
           ]

    assert result.return["programs-omitted"] == 0

    Application.put_env(
      :ptc_runner,
      :host_llm_test_result,
      {:ok,
       %{
         content: nil,
         tool_calls: [
           %{id: "terminal-fail", name: "run_ptc_lisp", args: %{"program" => "(fail :stop)"}}
         ],
         tokens: %{}
       }}
    )

    assert {:ok, failed, session} = ReplSession.eval(session, "(app/run {})")
    assert failed.return["status"] == "subject-failure"

    assert [
             %{
               :source => "(fail :stop)",
               "execution" => execution,
               "mission" => "default",
               "turn" => 1
             }
           ] = failed.return["programs"]

    assert execution["outcome"] == :failed
    assert execution["retryable?"]
    assert is_binary(execution["message"])

    assert {:ok, events} = ReplSession.close(session)

    workflow_ids =
      for %{type: "evaluation-started", data: %{environment: :workflow, evaluation_id: id}} <-
            events,
          do: id

    mission_parents =
      for %{type: "evaluation-started", data: %{environment: :mission, parent_evaluation_id: id}} <-
            events,
          do: id

    assert length(workflow_ids) == 2
    assert Enum.sort(mission_parents) == Enum.sort(workflow_ids)
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
  test "workflow and mission openings retain the sealed credential diagnostic", %{
    tmp_dir: directory
  } do
    configure_host_llm()

    for {policy, private_opts} <- [
          {:normal, []},
          {:private, [private_terminal: true]}
        ],
        target <- [:workflow, {:mission, "review"}] do
      {manifest, host} = write_missing_credential_application(directory, policy, target)
      mission_opts = if target == :workflow, do: [], else: [mission: elem(target, 1)]
      owners_before = provider_activity_owners()

      assert {:error,
              %{
                code: :credential_unavailable,
                diagnostic: %CommandDiagnostic{} = diagnostic,
                provider_activity: false
              }} =
               ManifestRepl.open(
                 manifest,
                 host,
                 [input_mode: :interactive, terminal_attached: true] ++
                   private_opts ++ mission_opts
               )

      assert CommandDiagnostic.valid?(diagnostic)
      assert diagnostic.phase == :active_preflight
      assert diagnostic.subject.name == "alpha"
      assert diagnostic.subject.operation == :credentials
      refute_received {:host_llm_ensure_ready, _worker}
      refute_received {:host_llm_request, _model, _request}

      assert_eventually(fn ->
        MapSet.difference(provider_activity_owners(), owners_before) == MapSet.new()
      end)
    end
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

    assert %{provider_activity: true, code: code, diagnostic: diagnostic} = failure
    assert is_atom(code)
    assert CommandDiagnostic.valid?(diagnostic)
    assert Enum.sort(Map.keys(failure)) == [:code, :diagnostic, :provider_activity]
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

  defp configure_host_llm(extra \\ []) do
    keys =
      [:llm_adapter, :host_llm_test_owner, :host_llm_test_ready_gate]
      |> Kernel.++(Keyword.keys(extra))
      |> Enum.uniq()

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
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
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
            "structured_output_mode" => "unsupported",
            "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
            "installation_revision" => "manifest-mission-repl-test-v1",
            "model" => "openrouter:test/model",
            "credential" => "key"
          }
        }
      })
    )

    {manifest, host}
  end

  defp write_missing_credential_application(directory, policy, target) do
    suffix = "#{policy}-#{System.unique_integer([:positive])}"
    write_component(directory)
    File.write!(Path.join(directory, "review.clj"), "(ns review)")
    manifest = Path.join(directory, "missing-credential-#{suffix}.json")
    host = Path.join(directory, "missing-credential-host-#{suffix}.json")

    declarations = [%{"name" => "alpha", "config" => %{}}, %{"name" => "omega", "config" => %{}}]

    providers =
      if target == :workflow,
        do: %{"workflow" => declarations, "mission" => []},
        else: %{"workflow" => [], "mission" => declarations}

    mission_providers = if target == :workflow, do: [], else: ["alpha", "omega"]

    document =
      manifest_document(policy, providers)
      |> Map.put("missions", %{
        "review" => %{
          "components" => [%{"id" => "review", "path" => "review.clj"}],
          "data" => %{},
          "providers" => mission_providers
        }
      })

    File.write!(manifest, Jason.encode!(document))

    installations =
      if target == :workflow,
        do: %{"alpha" => llm_installation("alpha-key"), "omega" => llm_installation("omega-key")},
        else: %{
          "alpha" => mcp_installation("alpha-key"),
          "omega" => mcp_installation("omega-key")
        }

    File.write!(
      host,
      Jason.encode!(%{
        "credentials" => %{
          "alpha-key" => %{"env" => "PTC_REPL_ABSENT_ALPHA_KEY"},
          "omega-key" => %{"env" => "PTC_REPL_ABSENT_OMEGA_KEY"}
        },
        "install" => installations
      })
    )

    {manifest, host}
  end

  defp llm_installation(credential) do
    %{
      "source" => "llm",
      "structured_output_mode" => "unsupported",
      "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
      "installation_revision" => "manifest-repl-missing-credential-v1",
      "model" => "openrouter:test/model",
      "credential" => credential
    }
  end

  defp mcp_installation(credential) do
    %{
      "source" => "mcp",
      "installation_revision" => "manifest-repl-missing-credential-v1",
      "transport" => %{
        "type" => "stdio",
        "command" => System.find_executable("sh"),
        "env" => %{"TOKEN" => %{"binding" => credential}}
      },
      "tools" => %{"read" => %{"as" => "#{credential}.read", "effect" => "read"}}
    }
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
