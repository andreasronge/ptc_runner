defmodule PtcRunner.TestSupport.RunCoordinatorExecutionFixture do
  @moduledoc false
  import ExUnit.Assertions

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventBudget
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.TestSupport.HostBoundFixture
  alias PtcRunner.TestSupport.TestHelpers

  def prepared_run(body, opts \\ []) do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}}
    }

    {limit_opts, request_opts} = Keyword.split(opts, [:evaluation_timeout_ms])

    limits =
      Map.new(limit_opts, fn {name, value} -> {Atom.to_string(name), value} end)

    manifest = if limits == %{}, do: manifest, else: Map.put(manifest, "limits", limits)

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] #{body})"
    }

    request_opts = Keyword.merge([result_projection: :json], request_opts)
    assert {:ok, request} = ApplicationPackage.request_memory("ptc.json", documents, request_opts)
    assert {:ok, catalog} = InstallationCatalog.new()
    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    {prepared, catalog}
  end

  def provider_prepared_run do
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: "owned-v1",
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
        selection_validation: :declarative,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    {:ok, capability} =
      Capability.new(
        name: "fixture",
        input_schema: %{"type" => "object", "additionalProperties" => false},
        callback: fn _arguments -> {:ok, %{}} end
      )

    staged = fn _selection, _context ->
      {:ok,
       %{
         credential_names: [],
         preflight: fn ->
           {:ok, fn %{} -> {:ok, %{capabilities: [capability]}} end}
         end
       }}
    end

    registration = %{
      descriptor: descriptor,
      implementation: %{builder: staged},
      authority: nil
    }

    assert {:ok, catalog} = InstallationCatalog.new(%{"selected" => registration})
    assert {:ok, services} = ProviderRuntimeServices.new()

    manifest =
      TestHelpers.valid_manifest(%{
        "providers" => %{
          "workflow" => [%{"name" => "selected", "config" => %{}}],
          "mission" => []
        }
      })

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (return {\"answer\" 42}))"
    }

    assert {:ok, request} =
             ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    {prepared, catalog, services}
  end

  # A host-bound catalog over a shipped source, because nothing else may declare
  # an audited-local check. The callback reports itself so a test can prove both
  # that phase 7 ran and where it stopped.
  def audited_local_prepared_run(failing) do
    parent = self()
    services = HostBoundFixture.runtime_services()
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :llm,
        installation_revision: "model-v1",
        credential_names: [],
        authorization_mode: :none,
        data_class: :normal,
        accepts_data: [:normal],
        requires: [],
        provides: [],
        destinations: [:workflow],
        workflow_llm?: true,
        connectivity_mode: :probe,
        probe_effect: :metadata,
        selection_validation: :declarative,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :audited_local
      )

    {:ok, capability} =
      Capability.new(
        name: "fixture",
        input_schema: %{"type" => "object", "additionalProperties" => false},
        callback: fn _arguments -> {:ok, %{}} end
      )

    # A host-bound catalog routes its builders through the real host
    # installation, so this one exists to satisfy registration parity and to
    # prove, by never being called, that a failed phase 7 stops before it.
    staged = fn _selection, _context ->
      send(parent, {:builder_invoked, "model"})

      {:ok,
       %{
         credential_names: [],
         preflight: fn ->
           {:ok, fn %{} -> {:ok, %{capabilities: [capability]}} end}
         end
       }}
    end

    implementation = %{
      builder: staged,
      connectivity_probe: fn _selection, _context, _services -> :ok end,
      local_preflight: fn _selection, _context, _services ->
        send(parent, {:audited_local, "model"})
        if failing, do: {:error, failing}, else: :ok
      end
    }

    registration = %{descriptor: descriptor, implementation: implementation, authority: nil}

    assert {:ok, catalog} =
             InstallationCatalog.new(%{"model" => registration},
               runtime_binding: services.runtime_binding
             )

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => [%{"name" => "model", "config" => %{}}],
        "mission" => []
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (return {\"answer\" 42}))"
    }

    assert {:ok, request} =
             ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    {prepared, catalog, services}
  end

  def oversized_metadata_prepared_run do
    padding = String.duplicate("a", 40)
    component_ids = Enum.map(1..96, &"component#{padding}#{&1}")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" =>
          [%{"id" => "app", "path" => "main.clj"}] ++
            Enum.map(component_ids, &%{"id" => &1, "path" => "#{&1}.clj"}),
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "limits" => %{"event_payload_bytes" => EventBudget.minimum_normal_payload_bytes()}
    }

    documents =
      Map.new(component_ids, &{"#{&1}.clj", "(ns #{&1})"})
      |> Map.put("ptc.json", Jason.encode!(manifest))
      |> Map.put("main.clj", "(ns app) (defn run [_input] (return 42))")

    assert {:ok, request} =
             ApplicationPackage.request_memory("ptc.json", documents, inspection_capture: true)

    assert {:ok, catalog} = InstallationCatalog.new()
    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    {prepared, catalog}
  end
end
