defmodule PtcRunner.Kernel.ProviderAcquisitionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderAcquisition
  alias PtcRunner.Kernel.ProviderActivity
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

  test "a run acquires the whole selection and each provider only its own credential" do
    # `:all` is the run and check target set. It takes the same sealed path a
    # narrowed connectivity target set takes, so the credential each provider
    # receives is decided by its own sealed declaration rather than by what its
    # preparation reported.
    context = fixture()

    assert {:ok, acquired} = acquire(context, :all)
    assert acquired_names(acquired) == ["alpha", "beta", "leaf"]

    assert_received {:credentials, "alpha", ["alpha-key"]}
    assert_received {:credentials, "beta", ["beta-key"]}
    assert_received {:credentials, "leaf", ["leaf-key"]}
  end

  test "a preparation is never served a credential another provider declared" do
    # "beta" declares no credential and reports one belonging to "alpha". That
    # name is inside the selection's resolved union, so a check bounded by the
    # union alone would hand alpha's secret to beta. The comparison is against
    # beta's own sealed declaration instead, and it runs before preflight — so
    # the disclosure is refused before the map is consulted at all.
    context = fixture(credential_names: %{"beta" => []}, drifting: %{"beta" => ["alpha-key"]})

    assert {:error, %CommandDiagnostic{} = diagnostic} = acquire(context, :all)
    assert diagnostic.phase == :provider_acquisition
    assert diagnostic.code == :provider_policy_changed
    assert diagnostic.subject.name == "beta"
    assert diagnostic.subject.operation == :acquisition

    assert_received {:resolved, ["alpha-key", "leaf-key"]}
    refute_received {:credentials, _name, _names}
    refute_received {:acquired, _name}
  end

  test "a sealed pair from another operation reaches no callback" do
    # Both applications have the same package digest — same manifest, same
    # documents — and differ only in the dependency graph their catalogs
    # describe. A plan projected from one pair therefore satisfies every
    # digest-shaped check while steering the other operation's closure, so the
    # binding that refuses it is the pairing itself and the session identity.
    context = fixture()
    other = fixture(graph: :independent)

    assert other.prepared.request.package.application_content_digest ==
             context.prepared.request.package.application_content_digest

    # A preparation and a catalog that were never validated together.
    assert {:error, :invalid_provider_acquisition} =
             ProviderAcquisition.acquire(
               context.prepared,
               other.catalog,
               context.registry,
               context.session,
               :all,
               %{}
             )

    # Another operation's legitimately sealed pair, run under this session.
    assert {:error, :invalid_provider_acquisition} =
             ProviderAcquisition.acquire(
               other.prepared,
               other.catalog,
               context.registry,
               context.session,
               :all,
               %{}
             )

    refute_received {:prepared, _name}
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
    # whether to invoke, so the graph is read from the sealed descriptors. The
    # same manifest over a catalog that seals no edge acquires beta alone,
    # which is what proves the descriptors decided the closure.
    assert {:ok, acquired} = acquire(fixture(graph: :independent), [workflow(1)])
    assert acquired_names(acquired) == ["beta"]
    refute_received {:prepared, "leaf"}

    assert {:ok, acquired} = acquire(fixture(), [workflow(1)])
    assert acquired_names(acquired) == ["beta", "leaf"]
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

    # Classified, because this is a command session: the drift is reported as the
    # closed policy-changed code naming the occurrence that drifted, rather than
    # as a bare atom the command boundary would collapse to `internal_error`.
    assert {:error, %CommandDiagnostic{} = diagnostic} = acquire(context, [workflow(1)])
    assert diagnostic.phase == :provider_acquisition
    assert diagnostic.code == :provider_policy_changed
    assert diagnostic.subject.name == "leaf"
    assert diagnostic.subject.operation == :acquisition

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

  test "a failure inside the closure leaves cleanup to the session that owns it" do
    context = fixture(failing: "beta")

    assert {:error, _reason} = acquire(context, [workflow(1)])
    assert_received {:acquired, "leaf"}
    refute_received {:closed, "leaf"}

    assert :ok = ProviderSession.close(context.session)
    assert_receive {:closed, "leaf"}, 5_000
  end

  test "an embedding keeps the bare reason a command has classified" do
    # Two callers, one pipeline. A command must classify — a `provider_acquisition`
    # code needs a subject bearing an occurrence, and this is the last frame that
    # has one. An embedding must not: it has no envelope to render a diagnostic
    # into, and the raw vocabulary is far richer than three closed codes can
    # express, so collapsing it would destroy information its callers rely on.
    # The two are told apart by the same question phase-8 credential resolution
    # asks — whether the session carries an operation deadline.
    context = fixture(failing: "leaf", failing_reason: :mcp_timeout)

    assert {:error, %CommandDiagnostic{} = diagnostic} = acquire(context, [workflow(1)])
    assert diagnostic.phase == :provider_acquisition
    # A budget that expired is not the same fact as a provider that could not be
    # reached, and it is the one an operator can act on: it names the ceiling to
    # raise. Retryable, because the common cause is a cold first launch.
    assert diagnostic.code == :provider_acquisition_timeout
    assert diagnostic.retryable
    assert diagnostic.subject.name == "leaf"

    embedded = fixture(failing: "leaf", failing_reason: :mcp_timeout, embedding: true)
    assert {:error, :mcp_timeout} = acquire_embedded(embedded)
  end

  test "an active session cannot take the embedding entry at all" do
    # The embedding entry is told apart from `acquire/6` by its session carrying
    # no operation deadline, and it must ask before any callback. An active
    # command reaching it would otherwise prepare and preflight every selected
    # provider — outside the sealed binding `acquire/6` checks and against its
    # own budget — and only be refused when it reached credential resolution.
    context = fixture()

    assert {:error, :invalid_provider_acquisition} = acquire_embedded(context)
    refute_received {:prepared, _name}
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
             context.session,
             true
           ) do
      ProviderAcquisition.acquire(
        context.prepared,
        context.catalog,
        context.registry,
        context.session,
        targets,
        credentials
      )
    end
  end

  # The embedding entry: no preparation, no catalog, and no phase-8 step 5, so
  # the registry resolves synchronously, exactly as `RunBuilder`'s embedding
  # path does.
  defp acquire_embedded(context) do
    ProviderAcquisition.acquire_embedded(
      context.package,
      context.registry,
      context.session,
      :normal,
      fn _effective_class -> :ok end
    )
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
    parent = self()

    {:ok, services} =
      ProviderRuntimeServices.new(
        credential_resolver: fn names ->
          send(parent, {:resolved, Enum.sort(names)})
          {:ok, Map.new(names, &{&1, "secret-#{&1}"})}
        end
      )

    {:ok, registry} = InstallationCatalog.runtime_registry(catalog, services)

    limits = prepared.request.package.limits
    {:ok, session} = ProviderSession.start_active(limits, prepared.attestation)

    # An embedding opens the plain session `RunBuilder` opens for it, which
    # carries no operation deadline — the same distinction acquisition uses to
    # decide whether to classify.
    {:ok, session} =
      if Keyword.get(options, :embedding) do
        # The unbegun session this fixture opened is not the one an embedding
        # uses, so it is closed here rather than left for creator death.
        ProviderSession.close(session)
        ProviderSession.start(limits)
      else
        # The activity marker an active command sets before any provider work,
        # which is half of what binds this session to this preparation.
        :ok = ProviderActivity.mark(prepared.provider_activity)
        ProviderSession.begin_operation(session, :run)
      end

    on_exit(fn ->
      ProviderSession.close(session)
      PreparedRun.close(prepared)
      InstallationCatalog.close(catalog)
    end)

    %{
      package: package,
      registry: registry,
      session: session,
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

  # `:independent` describes the same three aliases with no dependency edge at
  # all. The manifest is byte-identical either way, so the two applications
  # share a package digest and differ only in what their catalogs sealed.
  defp graph(:independent), do: [{"alpha", [], []}, {"beta", [], []}, {"leaf", [], []}]

  defp graph(_default),
    do: [{"alpha", [], []}, {"beta", [:leaf_service], []}, {"leaf", [], [:leaf_service]}]

  defp catalog(parent, options) do
    registrations =
      options
      |> Keyword.get(:graph)
      |> graph()
      |> Map.new(fn {name, requires, provides} ->
        {name, registration(parent, name, requires, provides, options)}
      end)

    {:ok, catalog} = InstallationCatalog.new(registrations)
    catalog
  end

  defp registration(parent, name, requires, provides, options) do
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})
    data_class = options |> Keyword.get(:data_class, %{}) |> Map.get(name, :normal)
    mission = Keyword.get(options, :mission, [])

    declared_credentials =
      options |> Keyword.get(:credential_names, %{}) |> Map.get(name, ["#{name}-key"])

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: "acquisition-v1",
        credential_names: declared_credentials,
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

    credentials = options |> Keyword.get(:drifting, %{}) |> Map.get(name, declared_credentials)

    implementation = %{
      builder:
        builder(
          parent,
          name,
          requires,
          provides,
          credentials,
          data_class,
          Keyword.get(options, :failing),
          Keyword.get(options, :failing_reason, :provider_unavailable)
        )
    }

    %{descriptor: descriptor, implementation: implementation, authority: nil}
  end

  defp builder(parent, name, requires, provides, credentials, data_class, failing, reason) do
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
            fn acquired_credentials, _services ->
              # What this provider was actually handed, which is the only way a
              # test can tell a refused disclosure from an unrelated failure.
              send(
                parent,
                {:credentials, name, acquired_credentials |> Map.keys() |> Enum.sort()}
              )

              if name == failing do
                {:error, reason}
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
