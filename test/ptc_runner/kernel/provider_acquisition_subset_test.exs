defmodule PtcRunner.Kernel.ProviderAcquisitionSubsetTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderAcquisition
  alias PtcRunner.Kernel.ProviderCredentials
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules

  test "only the sealed closure is ever prepared" do
    # Preparation is provider work, not a lookup: a prepare callback can fail
    # the operation, block until the deadline, and register provisional roots.
    # A provider outside the closure must therefore stay completely
    # callback-inert, not merely unacquired.
    context = fixture()

    assert {:ok, acquired} = acquire(context, [workflow(1)])
    assert acquired_names(acquired) == ["beta", "leaf"]

    assert_received {:prepared, "beta"}
    assert_received {:prepared, "leaf"}
    refute_received {:prepared, "alpha"}
    refute_received {:acquired, "alpha"}
  end

  test "an unrelated provider's sealed class still decides the application" do
    # The whole-application judgement survives without preparing anything,
    # because phase 5 already made it from sealed declarations: an application
    # whose classes disagree never becomes a preparation to acquire from, and
    # no builder ever runs to discover that.
    assert {:error, %CommandDiagnostic{} = diagnostic} =
             refused_preparation(data_class: %{"alpha" => :private_inspection})

    assert diagnostic.phase == :provider_declaration
    assert diagnostic.code == :data_policy_denied
    refute_received {:prepared, _name}
  end

  test "a subset needing nothing acquires only itself" do
    context = fixture()

    assert {:ok, acquired} = acquire(context, [workflow(0)])
    assert acquired_names(acquired) == ["alpha"]
    refute_received {:prepared, "beta"}
    refute_received {:prepared, "leaf"}
  end

  test "the closure follows sealed requires rather than callback reports" do
    # "beta" requires the service "leaf" provides. Deriving that from what the
    # builders report would mean invoking the very callbacks the plan decides
    # whether to invoke, so the graph is read from the sealed descriptors.
    context = fixture()

    assert {:ok, plan} = ProviderAcquisition.plan(context.prepared, context.catalog)
    assert Enum.map(plan.occurrences, & &1.name) == ["alpha", "beta", "leaf"]
    assert Enum.find(plan.occurrences, &(&1.name == "beta")).requires == [:leaf_service]
    assert Enum.find(plan.occurrences, &(&1.name == "leaf")).provides == [:leaf_service]

    assert {:ok, _acquired} = acquire(context, [workflow(1)])
    assert_received {:acquired, "leaf"}
  end

  test "the resolved union covers every selection, not only the acquired closure" do
    # The closure here is beta and leaf; alpha is outside it and stays
    # callback-inert. Its credential is resolved anyway, because the union comes
    # from the sealed selection rather than from whatever this operation happens
    # to acquire. That is what lets one connect settle a credentials row for an
    # occurrence no closure reaches, without a second derivation rule.
    context = fixture()

    assert {:ok, _acquired} = acquire(context, [workflow(1)])
    assert_received {:resolved, names}
    assert names == ["alpha-key", "beta-key", "leaf-key"]
    refute_received {:resolved, _other}
    refute_received {:prepared, "alpha"}
  end

  test "a preparation that contradicts its sealed declaration fails closed" do
    # Runtime binding compares the data policy only, so a builder could
    # otherwise widen its own credentials or dependencies after the plan that
    # authorised it was fixed. The credential it invented is not in the resolved
    # union either — the union is sealed, so a name a builder adds afterwards
    # can never appear in it — but the declaration check refuses this before
    # acquisition ever consults the map.
    context = fixture(drifting: %{"leaf" => ["extra-key"]})

    assert {:error, :provider_declaration_mismatch} = acquire(context, [workflow(1)])
    assert_received {:resolved, names}
    refute "extra-key" in names
    refute_received {:acquired, _name}
  end

  test "an unknown or empty target set costs no callback at all" do
    # Checked before preparation, so a caller cannot spend provider work on a
    # target that was never selected, and an empty set is refused rather than
    # succeeding with nothing acquired.
    context = fixture()

    for targets <- [[workflow(7)], [%{destination: :mission, index: 0}], []] do
      assert {:error, :invalid_provider_acquisition} = acquire(context, targets)
    end

    refute_received {:prepared, _name}
  end

  test "occurrence identity restarts per destination" do
    # The sealed declarations and `ConnectivityResult` both identify an
    # occurrence by `{destination, index}`. A single global counter would name
    # the first mission occurrence `1` and silently target a workflow provider.
    context = fixture(mission: ["leaf"])

    assert {:ok, acquired} = acquire(context, [%{destination: :mission, index: 0}])
    assert acquired_names(acquired) == ["leaf"]
    refute_received {:prepared, "alpha"}
  end

  test "a plan from another application is refused before preparation" do
    context = fixture()
    other = fixture(entry: "app/other")

    assert {:error, :invalid_provider_acquisition} =
             acquire(%{context | plan: other.plan}, [workflow(1)])

    refute_received {:prepared, _name}
  end

  test "a failure inside the closure leaves cleanup to the session that owns it" do
    context = fixture(failing: "beta")

    assert {:error, _reason} = acquire(context, [workflow(1)])
    assert_received {:acquired, "leaf"}
    refute_received {:closed, "leaf"}

    assert :ok = ProviderSession.close(context.session)
    assert_receive {:closed, "leaf"}, 5_000
  end

  # Credentials are resolved the way phase-8 step 5 resolves them, from the same
  # sealed pair, so these targets are acquired against the real union rather
  # than a map this file invented.
  defp acquire(context, targets) do
    with {:ok, credentials} <-
           ProviderCredentials.resolve(
             context.prepared,
             context.catalog,
             context.registry,
             context.session
           ) do
      ProviderAcquisition.acquire_targets(
        context.package,
        context.registry,
        context.session,
        targets,
        fn _effective_class -> :ok end,
        context.plan,
        credentials
      )
    end
  end

  defp workflow(index), do: %{destination: :workflow, index: index}

  defp acquired_names(acquired) do
    acquired.workflow.capabilities
    |> Enum.concat(acquired.mission.capabilities)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  # "alpha" stands alone and "beta" requires the service "leaf" provides. The
  # manifest order is alpha, beta, leaf, so a closure is never simply a prefix.
  defp fixture(options \\ []) do
    {:ok, prepared, catalog, package} = prepare(options)
    {:ok, plan} = ProviderAcquisition.plan(prepared, catalog)
    parent = self()

    {:ok, services} =
      ProviderRuntimeServices.new(
        credential_resolver: fn names ->
          send(parent, {:resolved, Enum.sort(names)})
          {:ok, Map.new(names, &{&1, "secret"})}
        end
      )

    {:ok, registry} = InstallationCatalog.runtime_registry(catalog, services)

    limits = prepared.request.package.limits
    {:ok, session} = ProviderSession.start_active(limits, prepared.attestation)
    {:ok, session} = ProviderSession.begin_operation(session, :run)

    on_exit(fn ->
      ProviderSession.close(session)
      PreparedRun.close(prepared)
      InstallationCatalog.close(catalog)
    end)

    %{
      package: package,
      registry: registry,
      session: session,
      plan: plan,
      prepared: prepared,
      catalog: catalog
    }
  end

  defp refused_preparation(options) do
    case prepare(options) do
      {:ok, _prepared, _catalog, _package} -> flunk("expected the preparation to be refused")
      {:error, diagnostic} -> {:error, diagnostic}
    end
  end

  defp prepare(options) do
    parent = self()
    catalog = catalog(parent, options)
    mission = Keyword.get(options, :mission, [])

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => Keyword.get(options, :entry, "app/run")
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => selections(["alpha", "beta", "leaf"] -- mission),
        "mission" => selections(mission)
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (return 1)) (defn other [_input] (return 2))"
    }

    {:ok, request} =
      ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    case RunCoordinator.prepare(request, catalog) do
      {:ok, prepared} -> {:ok, prepared, catalog, request.package}
      {:error, diagnostic} -> {:error, diagnostic}
    end
  end

  defp selections(names), do: Enum.map(names, &%{"name" => &1, "config" => %{}})

  defp catalog(parent, options) do
    registrations =
      Map.new(
        [{"alpha", [], []}, {"beta", [:leaf_service], []}, {"leaf", [], [:leaf_service]}],
        fn {name, requires, provides} ->
          {name, registration(parent, name, requires, provides, options)}
        end
      )

    {:ok, catalog} = InstallationCatalog.new(registrations)
    catalog
  end

  defp registration(parent, name, requires, provides, options) do
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})
    data_class = options |> Keyword.get(:data_class, %{}) |> Map.get(name, :normal)
    mission = Keyword.get(options, :mission, [])

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: "subset-v1",
        credential_names: ["#{name}-key"],
        authorization_mode: :none,
        data_class: data_class,
        accepts_data: [:normal],
        requires: requires,
        provides: provides,
        destinations: if(name in mission, do: [:mission], else: [:workflow]),
        workflow_llm?: false,
        connectivity_mode: :none,
        probe_effect: nil,
        selection_validation: :declarative,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    credentials = options |> Keyword.get(:drifting, %{}) |> Map.get(name, ["#{name}-key"])

    implementation = %{
      builder:
        builder(
          parent,
          name,
          requires,
          provides,
          credentials,
          data_class,
          Keyword.get(options, :failing)
        )
    }

    %{descriptor: descriptor, implementation: implementation, authority: nil}
  end

  defp builder(parent, name, requires, provides, credentials, data_class, failing) do
    fn _selection, _context ->
      send(parent, {:prepared, name})

      {:ok, capability} =
        Capability.new(
          name: name,
          input_schema: %{"type" => "object", "additionalProperties" => false},
          callback: fn _arguments -> {:ok, %{}} end
        )

      {:ok,
       %{
         credential_names: credentials,
         requires: requires,
         provides: provides,
         data_class: data_class,
         accepts_data: [:normal],
         preflight: fn ->
           {:ok,
            fn _credentials, _services ->
              if name == failing do
                {:error, :provider_unavailable}
              else
                send(parent, {:acquired, name})

                {:ok,
                 %{
                   capabilities: [capability],
                   close: fn -> send(parent, {:closed, name}) && :ok end,
                   exports: Map.new(provides, &{&1, name})
                 }}
              end
            end}
         end
       }}
    end
  end
end
