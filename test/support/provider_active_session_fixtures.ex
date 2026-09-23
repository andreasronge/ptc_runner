defmodule PtcRunner.TestSupport.ProviderActiveSessionFixtures do
  @moduledoc false

  # Shared by ProviderActiveSessionTest (async) and ProviderActiveSessionGlobalStateTest.

  import ExUnit.Assertions

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActiveSession
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules

  def fixture(
        callback,
        modes \\ ["first"],
        limits \\ nil,
        revision \\ "custom-v1",
        provider_application \\ nil,
        credential_names \\ [],
        manifest_limits \\ %{}
      ) do
    limits = limits || Limits.installed_defaults()
    {:ok, rules} = rules()

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: revision,
        credential_names: credential_names,
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
        implementation = %{
          builder: fn _selection, _context -> {:error, :inactive_provider} end,
          selection_validator: callback
        }

        implementation =
          if provider_application,
            do: Map.put(implementation, :provider_application, provider_application),
            else: implementation

        {name,
         %{
           descriptor: descriptor,
           implementation: implementation,
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
      },
      "limits" => manifest_limits
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

  def rules do
    SelectionRules.new(
      fields: %{
        "mode" => %{type: :string, input: true, required: true, members: "modes"}
      },
      cross_rules: [],
      named_sets: %{"modes" => ["first", "second"]}
    )
  end

  def close(session, prepared) do
    assert :ok = ProviderSession.close(session)
    assert :ok = PreparedRun.close(prepared)
  end

  # The execution owner is the only session opener left, so tests take the same
  # route it does: open the owner's sinks (which consumes the prepared run),
  # hand the session to a fixed lifecycle owner, and begin the run there.
  def open_owned(prepared, catalog, services) do
    with {:ok, _inputs} <- owned_inputs(prepared),
         {:ok, session} <- open_owned_setup(prepared, catalog, services) do
      ProviderActiveSession.begin_owned_operation(session, prepared, catalog, services, :run)
    end
  end

  def open_owned_setup(prepared, catalog, services) do
    with {:ok, _inputs} <- owned_inputs(prepared) do
      ProviderActiveSession.open_consumed_setup(
        prepared,
        catalog,
        services,
        self(),
        fn _session -> :ok end
      )
    end
  end

  # Opened once per prepared run and remembered, because opening the sinks is
  # what consumes it. A spawned build passes the captured value explicitly,
  # since it does not inherit this process's dictionary. The sinks monitor the
  # process that opened them and exit with it, so no test teardown is needed —
  # and registering one here would raise in a spawned caller.
  def owned_inputs(prepared) do
    case Process.get({:owned_inputs, prepared.attestation}) do
      nil ->
        with {:ok, authority} <- PublicationAuthority.new([]),
             {:ok, sinks} <- RunBuilder.open_prepared_sinks(prepared, authority, self()) do
          Process.put({:owned_inputs, prepared.attestation}, {authority, sinks})
          {:ok, {authority, sinks}}
        end

      inputs ->
        {:ok, inputs}
    end
  end

  def services(mode \\ :host_owned) do
    {:ok, services} = ProviderRuntimeServices.new(provider_application_mode: mode)
    services
  end
end
