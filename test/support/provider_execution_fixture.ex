defmodule PtcRunner.TestSupport.ProviderExecutionFixture do
  @moduledoc false
  import ExUnit.Callbacks, only: [on_exit: 1]
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.ResourceRegistrar
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules

  def provider_fixture(opts \\ []) do
    parent = self()
    selection_validation = Keyword.get(opts, :selection_validation, :declarative)
    body = Keyword.get(opts, :body, "(return {\"answer\" 42})")
    credential_names = Keyword.get(opts, :credential_names, [])

    # The default acquisition registers a resource root, so a refusal test can
    # prove nothing was created rather than that nothing could have been.
    acquire =
      Keyword.get(opts, :acquire, fn context ->
        scoped_root(parent, context)
        fixture_capability()
      end)

    staged_policy =
      %{
        data_class: Keyword.get(opts, :staged_data_class),
        accepts_data: Keyword.get(opts, :staged_accepts_data)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: Keyword.get(opts, :installation_revision, "lifecycle-v1"),
        credential_names: credential_names,
        authorization_mode: :none,
        data_class: Keyword.get(opts, :descriptor_data_class, :normal),
        accepts_data: Keyword.get(opts, :descriptor_accepts_data, [:normal]),
        requires: [],
        provides: [],
        destinations: [:workflow],
        workflow_llm?: false,
        connectivity_mode: Keyword.get(opts, :connectivity_mode, :none),
        probe_effect: nil,
        selection_validation: selection_validation,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    builder = fn _selection, context ->
      send(parent, {:provider_phase, :prepare})

      staged = %{
        credential_names: Keyword.get(opts, :builder_credential_names, credential_names),
        preflight: fn ->
          send(parent, {:provider_phase, :preflight})

          {:ok,
           fn %{} ->
             send(parent, {:provider_phase, :acquire})
             acquire.(context)
           end}
        end
      }

      {:ok, Map.merge(staged, staged_policy)}
    end

    implementation =
      if selection_validation == :active do
        Map.put(
          %{builder: builder},
          :selection_validator,
          Keyword.fetch!(opts, :selection_validator)
        )
      else
        %{builder: builder}
      end

    implementation =
      case Keyword.fetch(opts, :provider_application) do
        {:ok, application} -> Map.put(implementation, :provider_application, application)
        :error -> implementation
      end

    registration = %{descriptor: descriptor, implementation: implementation, authority: nil}

    {:ok, installed_limits} =
      Limits.installed(%{
        doctor_connectivity_timeout_ms: Keyword.get(opts, :doctor_connectivity_timeout_ms, 10_000)
      })

    {:ok, catalog} =
      InstallationCatalog.new(%{"selected" => registration}, installed_limits: installed_limits)

    default_resolver = fn names ->
      send(parent, {:resolved_credentials, names})
      {:ok, Map.new(names, &{&1, "fixture-credential"})}
    end

    {:ok, services} =
      ProviderRuntimeServices.new(
        activation: Keyword.get(opts, :activation, fn -> {:ok, nil} end),
        credential_resolver: Keyword.get(opts, :credential_resolver, default_resolver),
        provider_application_mode: Keyword.get(opts, :provider_application_mode, :host_owned)
      )

    {:ok, execution} = ProviderExecution.new(catalog, services, [])
    {:ok, authority} = PublicationAuthority.new([])

    manifest = manifest()

    manifest =
      if Keyword.get(opts, :provider_free, false),
        do: Map.delete(manifest, "providers"),
        else: manifest

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] #{body})"
    }

    {:ok, request} =
      ApplicationPackage.request_memory("ptc.json", documents,
        result_projection: :json,
        installed_limits: installed_limits
      )

    {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    on_exit(fn -> InstallationCatalog.close(catalog) end)

    %{
      prepared: prepared,
      catalog: catalog,
      execution: execution,
      authority: authority
    }
  end

  # ex_dna:disable-for-next-line — lifecycle setup independent of privacy/publication fixtures
  defp manifest do
    %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => [%{"name" => "selected", "config" => %{}}],
        "mission" => []
      }
    }
  end

  def scoped_root(parent, context) do
    spawn(fn ->
      signal = Process.monitor(context.owner)

      send(
        parent,
        {:provider_root, self(), ResourceRegistrar.register_root(context.resource_registrar)}
      )

      receive do
        {:DOWN, ^signal, :process, _pid, _reason} -> :ok
      end
    end)
  end

  def fixture_capability do
    Capability.new(
      name: "fixture",
      input_schema: %{"type" => "object", "additionalProperties" => false},
      callback: fn _arguments -> {:ok, %{}} end
    )
  end
end
