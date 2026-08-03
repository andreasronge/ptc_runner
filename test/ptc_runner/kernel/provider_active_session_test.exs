defmodule PtcRunner.Kernel.ProviderActiveSessionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActiveSession
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules

  test "active validators run in declaration order after activity is marked" do
    parent = self()

    validator = fn selection, context ->
      send(parent, {:validated, selection["mode"], context.deadline_ms})

      :ok
    end

    {:ok, prepared, catalog} = fixture(validator, ["first", "second"])

    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog)
    assert_receive {:validated, "first", first_deadline}
    assert_receive {:validated, "second", second_deadline}
    assert is_integer(first_deadline)
    assert second_deadline >= first_deadline
    assert ProviderActivity.value(prepared.provider_activity) == true

    close(session, prepared)
  end

  test "selection rejection returns the closed occurrence diagnostic" do
    {:ok, prepared, catalog} =
      fixture(fn _selection, _context -> {:error, :selection_rejected} end)

    assert {:error, %CommandDiagnostic{} = diagnostic} =
             ProviderActiveSession.open(prepared, catalog)

    assert diagnostic.phase == :active_preflight
    assert diagnostic.code == :selection_rejected
    assert diagnostic.provider_activity == true
    assert diagnostic.subject.name == "selected"
    assert diagnostic.subject.operation == :selection
    assert diagnostic.subject.occurrence == %{destination: :workflow, index: 0}
    assert ProviderActivity.value(prepared.provider_activity) == :unknown
  end

  test "invalid callback results and callback exits are selection failures" do
    for callback <- [
          fn _selection, _context -> :invalid end,
          fn _selection, _context -> exit(:fixture_failure) end
        ] do
      {:ok, prepared, catalog} = fixture(callback)

      assert {:error, %CommandDiagnostic{code: :selection_validation_failed}} =
               ProviderActiveSession.open(prepared, catalog)
    end
  end

  test "a blocked validator is killed at its intrinsic deadline" do
    parent = self()

    validator = fn _selection, _context ->
      send(parent, {:validator_started, self()})
      receive do: (:never -> :ok)
    end

    {:ok, limits} = Limits.new(selection_validation_timeout_ms: 100)
    {:ok, prepared, catalog} = fixture(validator, ["first"], limits)

    assert {:error, %CommandDiagnostic{code: :selection_validation_timeout}} =
             ProviderActiveSession.open(prepared, catalog)

    assert_receive {:validator_started, worker}
    refute Process.alive?(worker)
  end

  test "a queued success is rejected after the absolute deadline" do
    parent = self()

    owner =
      spawn(fn ->
        validator = fn _selection, _context ->
          send(parent, {:late_result_worker, self()})
          receive do: (:finish -> :ok)
        end

        {:ok, limits} = Limits.new(selection_validation_timeout_ms: 100)
        {:ok, prepared, catalog} = fixture(validator, ["first"], limits)
        send(parent, {:late_result, ProviderActiveSession.open(prepared, catalog)})
      end)

    assert_receive {:late_result_worker, worker}
    assert true = :erlang.suspend_process(owner)
    worker_ref = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}

    Process.send_after(self(), :resume_late_result_owner, 150)
    assert_receive :resume_late_result_owner, 500
    assert true = :erlang.resume_process(owner)

    assert_receive {:late_result,
                    {:error, %CommandDiagnostic{code: :selection_validation_timeout}}},
                   2_000
  end

  test "validator roots are provisional and gone before open returns" do
    parent = self()

    validator = fn _selection, context ->
      validator_worker = self()

      root =
        spawn(fn ->
          signal_ref = Process.monitor(context.owner)
          assert :ok = ResourceRegistrar.register_root(context.resource_registrar)
          send(validator_worker, {:root_registered, self()})

          receive do
            {:DOWN, ^signal_ref, :process, _pid, _reason} -> :ok
          end
        end)

      assert_receive {:root_registered, ^root}
      send(parent, {:validator_root, root})
      :ok
    end

    {:ok, prepared, catalog} = fixture(validator)
    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog)
    assert_receive {:validator_root, root}
    root_ref = Process.monitor(root)
    assert_receive {:DOWN, ^root_ref, :process, ^root, reason}, 2_000
    assert reason in [:normal, :noproc]

    close(session, prepared)
  end

  test "caller death kills validator work and drains its registered root" do
    parent = self()

    owner =
      spawn(fn ->
        validator = fn _selection, context ->
          validator_worker = self()

          root =
            spawn(fn ->
              signal_ref = Process.monitor(context.owner)
              assert :ok = ResourceRegistrar.register_root(context.resource_registrar)
              send(validator_worker, {:caller_death_root, self()})

              receive do
                {:DOWN, ^signal_ref, :process, _pid, _reason} -> :ok
              end
            end)

          send(parent, {:caller_death_worker, self()})
          assert_receive {:caller_death_root, ^root}
          send(parent, {:caller_death_root, root})
          receive do: (:never -> :ok)
        end

        {:ok, prepared, catalog} = fixture(validator)
        ProviderActiveSession.open(prepared, catalog)
      end)

    assert_receive {:caller_death_worker, worker}
    assert_receive {:caller_death_root, root}
    worker_ref = Process.monitor(worker)
    root_ref = Process.monitor(root)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert_receive {:DOWN, ^root_ref, :process, ^root, _reason}, 2_000
  end

  test "a prepared run cannot be opened with another sealed catalog" do
    callback = fn _selection, _context -> :ok end
    {:ok, prepared, _catalog} = fixture(callback)
    {:ok, other_prepared, other_catalog} = fixture(callback, ["first"], nil, "other-v1")

    assert {:error, %CommandDiagnostic{phase: :internal, provider_activity: false}} =
             ProviderActiveSession.open(prepared, other_catalog)

    assert ProviderActivity.value(prepared.provider_activity) == false
    PreparedRun.close(prepared)
    PreparedRun.close(other_prepared)
  end

  test "callbacks receive only an absolute deadline and scoped runtime owners" do
    validator = fn _selection, context ->
      assert Deadline.valid?(context.deadline)
      assert context.deadline_ms == Deadline.expires_at(context.deadline)
      assert Deadline.remaining(context.deadline) > 0
      assert is_pid(context.owner)
      assert %ResourceRegistrar{} = context.resource_registrar
      refute Map.has_key?(context, :credential_resolver)
      :ok
    end

    {:ok, prepared, catalog} = fixture(validator)
    assert {:ok, session} = ProviderActiveSession.open(prepared, catalog)
    close(session, prepared)
  end

  defp fixture(callback, modes \\ ["first"], limits \\ nil, revision \\ "custom-v1") do
    limits = limits || Limits.installed_defaults()
    {:ok, rules} = rules()

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: revision,
        credential_names: [],
        authorization_mode: :none,
        data_class: :normal,
        accepts_data: [:normal],
        requires: [],
        provides: [],
        destinations: [:workflow],
        workflow_llm?: false,
        connectivity_mode: :none,
        probe_effect: nil,
        selection_validation: :active,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    aliases =
      if modes == ["first"],
        do: ["selected"],
        else: Enum.map(Enum.with_index(modes), fn {_mode, index} -> "selected-#{index}" end)

    registrations =
      Map.new(aliases, fn name ->
        {name,
         %{
           descriptor: descriptor,
           implementation: %{
             builder: fn _selection, _context -> {:error, :inactive_provider} end,
             selection_validator: callback
           },
           authority: nil
         }}
      end)

    {:ok, catalog} = InstallationCatalog.new(registrations, installed_limits: limits)

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" =>
          Enum.zip_with(aliases, modes, fn name, mode ->
            %{"name" => name, "config" => %{"mode" => mode}}
          end),
        "mission" => []
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [input] (return input))"
    }

    with {:ok, request} <-
           ApplicationPackage.request_memory("ptc.json", documents,
             installed_limits: limits,
             result_projection: :json
           ),
         {:ok, prepared} <- RunCoordinator.prepare(request, catalog) do
      {:ok, prepared, catalog}
    end
  end

  defp rules do
    SelectionRules.new(
      fields: %{
        "mode" => %{type: :string, input: true, required: true, members: "modes"}
      },
      cross_rules: [],
      named_sets: %{"modes" => ["first", "second"]}
    )
  end

  defp close(session, prepared) do
    assert :ok = ProviderSession.close(session)
    assert :ok = PreparedRun.close(prepared)
  end
end
