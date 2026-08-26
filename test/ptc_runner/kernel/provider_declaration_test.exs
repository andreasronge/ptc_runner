defmodule PtcRunner.Kernel.ProviderDeclarationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.EffectiveApplication
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.HostInstallationAuthority
  alias PtcRunner.Kernel.HostInstallationOwner
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Context, as: OAuthContext
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderActivity
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.ProviderSnapshot
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.Kernel.TypedCanonicalJSON
  alias PtcRunner.Test.MCPOAuthRecordingStore
  alias PtcRunner.TestSupport.HostBoundFixture
  alias PtcRunner.TestSupport.TestHelpers

  @moduletag :tmp_dir
  @dense_services ~w(
    dense_service_01 dense_service_02 dense_service_03 dense_service_04
    dense_service_05 dense_service_06 dense_service_07 dense_service_08
    dense_service_09 dense_service_10 dense_service_11 dense_service_12
    dense_service_13 dense_service_14 dense_service_15 dense_service_16
    dense_service_17 dense_service_18 dense_service_19 dense_service_20
    dense_service_21 dense_service_22 dense_service_23 dense_service_24
    dense_service_25 dense_service_26 dense_service_27 dense_service_28
    dense_service_29 dense_service_30 dense_service_31 dense_service_32
  )a

  test "provider registration enforces descriptor and implementation consistency" do
    assert {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    base = [
      source: :custom,
      installation_revision: "custom-v1",
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
      local_preflight: :none
    ]

    assert {:ok, descriptor} = ProviderDescriptor.new(base)

    builder = fn _selection, _context -> {:error, :inactive_provider} end
    probe = fn _selection, _context, _services -> :ok end

    assert {:ok, catalog} =
             InstallationCatalog.new(%{
               "custom" => %{
                 descriptor: descriptor,
                 authority: nil,
                 implementation: %{builder: builder, connectivity_probe: probe}
               }
             })

    assert InstallationCatalog.valid?(catalog)

    assert {:error, :invalid_installation_catalog} =
             InstallationCatalog.new(%{
               "custom" => %{
                 descriptor: descriptor,
                 authority: nil,
                 implementation: %{builder: builder}
               }
             })

    assert {:ok, active} =
             ProviderDescriptor.new(
               Keyword.merge(base,
                 connectivity_mode: :none,
                 probe_effect: nil,
                 selection_validation: :active,
                 workflow_llm?: false
               )
             )

    assert {:error, :invalid_installation_catalog} =
             InstallationCatalog.new(%{
               "custom" => %{
                 descriptor: active,
                 authority: nil,
                 implementation: %{builder: builder}
               }
             })

    assert {:error, :invalid_installation_catalog} =
             InstallationCatalog.new(%{
               "custom" => %{
                 descriptor: descriptor,
                 authority: nil,
                 implementation: %{
                   builder: builder,
                   connectivity_probe: probe,
                   selection_validator: fn _selection, _context -> :ok end
                 }
               }
             })

    assert {:error, :invalid_installation_catalog} =
             InstallationCatalog.new(%{}, owner: self())
  end

  test "an audited-local declaration requires a shipped source and a host binding" do
    # `:audited_local` permits phase 7 to run a callback before provider
    # activity is marked, so it is a trust claim rather than a capability flag.
    # Neither half of the rule may be relaxed by whoever assembles the catalog.
    assert {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    base = [
      source: :custom,
      installation_revision: "custom-v1",
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
    ]

    assert {:error, :invalid_provider_descriptor} = ProviderDescriptor.new(base)

    # A custom registration declares the check it does have, and that value is
    # accepted: the rule restricts the trust level, not local checks as such.
    assert {:ok, unverified} =
             ProviderDescriptor.new(Keyword.put(base, :local_preflight, :unverified))

    assert unverified.local_preflight == :unverified

    assert {:ok, shipped} = ProviderDescriptor.new(Keyword.put(base, :source, :llm))
    assert shipped.local_preflight == :audited_local
    assert shipped.structured_output_mode == :unsupported

    assert {:error, :invalid_provider_descriptor} =
             ProviderDescriptor.new(
               Keyword.merge(base,
                 local_preflight: :unverified,
                 structured_output_mode: :json_schema
               )
             )

    builder = fn _selection, _context -> {:error, :inactive_provider} end
    probe = fn _selection, _context, _services -> :ok end
    check = fn _selection, _context, _services -> :ok end

    registrations = fn descriptor ->
      %{
        "checked" => %{
          descriptor: descriptor,
          authority: nil,
          implementation: %{
            builder: builder,
            connectivity_probe: probe,
            local_preflight: check
          }
        }
      }
    end

    # An unbound catalog is assembled by its embedder rather than derived from a
    # host document, so it cannot carry the claim even for a shipped source.
    assert {:error, :invalid_installation_catalog} =
             InstallationCatalog.new(registrations.(shipped))

    assert {:ok, unverified_catalog} = InstallationCatalog.new(registrations.(unverified))
    assert InstallationCatalog.valid?(unverified_catalog)

    binding = HostBoundFixture.runtime_services().runtime_binding

    assert {:ok, catalog} =
             InstallationCatalog.new(registrations.(shipped), runtime_binding: binding)

    assert InstallationCatalog.valid?(catalog)
  end

  test "selection rules reject executable or caller-owned schema terms" do
    for forbidden <- [
          fn -> :effect end,
          ~r/secret/,
          {__MODULE__, :callback, []},
          %{schema: %{"type" => "string"}}
        ] do
      assert {:error, :invalid_selection_rules} =
               SelectionRules.new(
                 fields: %{
                   "value" => %{type: :string, input: true, default: forbidden}
                 },
                 cross_rules: [],
                 named_sets: %{}
               )
    end

    assert {:error, :invalid_selection_rules} =
             SelectionRules.new(
               fields: %{
                 "value" => %{
                   type: :integer,
                   input: true,
                   default: 11,
                   minimum: 1,
                   maximum: 10
                 }
               },
               cross_rules: [],
               named_sets: %{}
             )

    assert {:ok, lower_bound} =
             SelectionRules.new(
               fields: %{"value" => %{type: :integer, input: true, minimum: 5}},
               cross_rules: [],
               named_sets: %{}
             )

    assert {:error, :invalid_selection} =
             SelectionRules.normalize(lower_bound, %{"value" => 3}, Limits.installed_defaults())

    assert {:ok, upper_bound} =
             SelectionRules.new(
               fields: %{"value" => %{type: :integer, input: true, maximum: 5}},
               cross_rules: [],
               named_sets: %{}
             )

    assert {:error, :invalid_selection} =
             SelectionRules.normalize(upper_bound, %{"value" => 7}, Limits.installed_defaults())
  end

  test "selection rules order forward defaults and reject cycles" do
    assert {:ok, forward} =
             SelectionRules.new(
               fields: %{
                 "a" => %{
                   type: {:unique_list, :string},
                   input: false,
                   default: {:intersection, "z", "visible"},
                   members: "visible"
                 },
                 "z" => %{
                   type: {:unique_list, :string},
                   input: true,
                   default: {:named_set, "all"},
                   members: "all"
                 }
               },
               cross_rules: [],
               named_sets: %{"all" => ["hidden", "visible"], "visible" => ["visible"]}
             )

    assert {:ok, %{"a" => ["visible"], "z" => ["hidden", "visible"]}} =
             SelectionRules.normalize(forward, %{}, Limits.installed_defaults())

    assert {:error, :invalid_selection_rules} =
             SelectionRules.new(
               fields: %{
                 "a" => %{
                   type: {:unique_list, :string},
                   input: false,
                   default: {:intersection, "b", "all"}
                 },
                 "b" => %{
                   type: {:unique_list, :string},
                   input: false,
                   default: {:intersection, "a", "all"}
                 }
               },
               cross_rules: [],
               named_sets: %{"all" => ["value"]}
             )
  end

  test "unique-list minimums reject explicit empty selections but retain non-empty defaults" do
    assert {:ok, rules} =
             SelectionRules.new(
               fields: %{
                 "allow" => %{
                   type: {:unique_list, :string},
                   input: true,
                   default: {:named_set, "all"},
                   minimum_items: 1,
                   members: "all"
                 }
               },
               cross_rules: [],
               named_sets: %{"all" => ["read"]}
             )

    assert {:ok, %{"allow" => ["read"]}} =
             SelectionRules.normalize(rules, %{}, Limits.installed_defaults())

    assert {:error, :invalid_selection} =
             SelectionRules.normalize(rules, %{"allow" => []}, Limits.installed_defaults())

    assert {:error, {:field, "allow"}} =
             SelectionRules.explain(rules, %{"allow" => []}, Limits.installed_defaults())
  end

  test "runtime normalization admits only the exact sealed canonical form" do
    assert {:ok, rules} =
             SelectionRules.new(
               fields: %{
                 "input" => %{type: :integer, input: true, default: 3, minimum: 1, maximum: 5},
                 "installed" => %{
                   type: :integer,
                   input: false,
                   default: 7,
                   minimum: 1,
                   maximum: 7
                 }
               },
               cross_rules: [],
               named_sets: %{}
             )

    limits = Limits.installed_defaults()
    canonical = %{"input" => 4, "installed" => 7}

    assert {:ok, ^canonical} = SelectionRules.normalize_runtime(rules, %{"input" => 4}, limits)
    assert {:ok, ^canonical} = SelectionRules.normalize_runtime(rules, canonical, limits)

    assert {:error, :invalid_selection} =
             SelectionRules.normalize_runtime(rules, %{canonical | "installed" => 6}, limits)
  end

  test "content identity changes both provider snapshot hashes" do
    assert {:ok, catalog} = custom_catalog()
    descriptor = catalog.descriptors["selected"]
    hash_a = "sha256:" <> String.duplicate("a", 64)
    hash_b = "sha256:" <> String.duplicate("b", 64)

    assert {:ok, first} =
             ProviderSnapshot.build(
               descriptor,
               "selected",
               %{"mode" => "a"},
               %{"count" => 1},
               hash_a
             )

    assert {:ok, second} =
             ProviderSnapshot.build(
               descriptor,
               "selected",
               %{"mode" => "a"},
               %{"count" => 1},
               hash_b
             )

    refute first["acquisition_identity_hash"] == second["acquisition_identity_hash"]
    refute first["snapshot_hash"] == second["snapshot_hash"]
    assert first["content_snapshot_hash"] == hash_a
    assert second["content_snapshot_hash"] == hash_b

    assert {:ok, acquisition_bytes} = DeterministicJSON.encode(first["acquisition"])

    assert first["acquisition_identity_hash"] ==
             :crypto.hash(:sha256, acquisition_bytes) |> Base.encode16(case: :lower)
  end

  test "installation config digest changes snapshot identity without changing acquisition identity" do
    assert {:ok, catalog} = custom_catalog()
    descriptor = catalog.descriptors["selected"]
    digest_a = "sha256:" <> String.duplicate("a", 64)
    digest_b = "sha256:" <> String.duplicate("b", 64)

    assert {:ok, first} =
             ProviderSnapshot.build(
               descriptor,
               "selected",
               %{"mode" => "a"},
               %{"count" => 1},
               nil,
               digest_a
             )

    assert {:ok, second} =
             ProviderSnapshot.build(
               descriptor,
               "selected",
               %{"mode" => "a"},
               %{"count" => 1},
               nil,
               digest_b
             )

    assert {:ok, omitted} =
             ProviderSnapshot.build(
               descriptor,
               "selected",
               %{"mode" => "a"},
               %{"count" => 1}
             )

    assert first["acquisition_identity_hash"] == second["acquisition_identity_hash"]
    assert first["acquisition_identity_hash"] == omitted["acquisition_identity_hash"]
    refute first["snapshot_hash"] == second["snapshot_hash"]
    refute first["snapshot_hash"] == omitted["snapshot_hash"]
    assert first["installation_config_digest"] == digest_a
    assert second["installation_config_digest"] == digest_b
    refute Map.has_key?(omitted, "installation_config_digest")
  end

  test "host authority follows its creator and transfers an explicit registry closer" do
    parent = self()

    document = %{
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "installation_revision" => "history-v1",
          "directory" => "traces"
        }
      }
    }

    creator =
      spawn(fn ->
        assert {:ok, decoded} = HostConfig.decode(document, "/tmp")

        host =
          struct!(HostConfig,
            path: "/tmp/ptc-host.json",
            directory: "/tmp",
            runtime: decoded.runtime,
            limits: decoded.limits,
            credentials: decoded.credentials,
            install: decoded.install
          )

        assert {:ok, services} = HostInstallation.runtime_services(host)
        assert {:ok, authority} = ProviderRuntimeServices.activate(services)
        send(parent, {:catalog_owner, authority.pid})
      end)

    creator_monitor = Process.monitor(creator)
    assert_receive {:catalog_owner, owner}
    owner_monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^creator_monitor, :process, ^creator, :normal}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, owner_reason}
    assert owner_reason in [:normal, :noproc]

    assert {:ok, decoded} = HostConfig.decode(document, "/tmp")

    host =
      struct!(HostConfig,
        path: "/tmp/ptc-host.json",
        directory: "/tmp",
        runtime: decoded.runtime,
        limits: decoded.limits,
        credentials: decoded.credentials,
        install: decoded.install
      )

    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, services} = HostInstallation.runtime_services(host)
    assert {:ok, registry} = InstallationCatalog.runtime_registry(catalog, services)
    registry_owner = registry.authority_owner.pid
    assert Process.alive?(registry_owner)
    assert :ok = InstallationCatalog.close(catalog)
    assert Process.alive?(registry_owner)
    assert :ok = :sys.suspend(registry_owner)
    assert :ok = InstallationCatalog.close(catalog)
    assert Process.alive?(registry_owner)
    assert :ok = :sys.resume(registry_owner)
    registry_owner_monitor = Process.monitor(registry_owner)
    assert :ok = ProviderRegistry.close(registry)
    assert_receive {:DOWN, ^registry_owner_monitor, :process, ^registry_owner, :normal}
  end

  test "named-set defaults must satisfy unique-list minimums" do
    assert {:error, :invalid_selection_rules} =
             SelectionRules.new(
               fields: %{
                 "items" => %{
                   type: {:unique_list, :string},
                   input: false,
                   default: {:named_set, "empty"},
                   minimum_items: 1,
                   members: "empty"
                 }
               },
               cross_rules: [],
               named_sets: %{"empty" => []}
             )
  end

  test "closing a suspended authority owner confirms terminal shutdown" do
    document = %{
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "installation_revision" => "history-v1",
          "directory" => "traces"
        }
      }
    }

    assert {:ok, decoded} = HostConfig.decode(document, "/tmp")

    host =
      struct!(HostConfig,
        path: "/tmp/ptc-host.json",
        directory: "/tmp",
        runtime: decoded.runtime,
        limits: decoded.limits,
        credentials: decoded.credentials,
        install: decoded.install
      )

    assert {:ok, authority} = HostInstallationOwner.start(host)
    owner = authority.pid
    monitor = Process.monitor(owner)
    assert true = :erlang.suspend_process(owner)
    assert :ok = HostInstallationAuthority.close(authority)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
  end

  test "closing a malformed authority cannot terminate an unrelated suspended process" do
    victim = spawn(fn -> receive do: (:stop -> :ok) end)
    monitor = Process.monitor(victim)
    assert true = :erlang.suspend_process(victim)

    forged = %HostInstallationAuthority{
      pid: victim,
      token: make_ref(),
      role: :catalog,
      fence: :atomics.new(1, signed: true),
      lease_owner: victim,
      lease_fence: :atomics.new(1, signed: false),
      lease_table: make_ref(),
      attestation: <<>>
    }

    assert :ok = HostInstallationAuthority.close(forged)
    assert Process.alive?(victim)
    assert true = :erlang.resume_process(victim)
    send(victim, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^victim, :normal}
  end

  test "a timed-out transfer cannot commit after the host owner resumes" do
    document = %{
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "installation_revision" => "history-v1",
          "directory" => "traces"
        }
      }
    }

    assert {:ok, decoded} = HostConfig.decode(document, "/tmp")

    host =
      struct!(HostConfig,
        path: "/tmp/ptc-host.json",
        directory: "/tmp",
        runtime: decoded.runtime,
        limits: decoded.limits,
        credentials: decoded.credentials,
        install: decoded.install
      )

    assert {:ok, authority} = HostInstallationOwner.start(host)
    owner = authority.pid
    assert :ok = :sys.suspend(owner)

    transfer =
      Task.async(fn -> HostInstallationAuthority.transfer_to_registry(authority, self()) end)

    assert Task.yield(transfer, 1_250) ==
             {:ok, {:error, :invalid_host_installation_authority}}

    monitor = Process.monitor(owner)
    assert :ok = :sys.resume(owner)
    assert :ok = HostInstallationAuthority.close(authority)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "authority close cancels a pending transfer before forcing suspended cleanup" do
    document = %{
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "installation_revision" => "history-v1",
          "directory" => "traces"
        }
      }
    }

    assert {:ok, decoded} = HostConfig.decode(document, "/tmp")

    host =
      struct!(HostConfig,
        path: "/tmp/ptc-host.json",
        directory: "/tmp",
        runtime: decoded.runtime,
        limits: decoded.limits,
        credentials: decoded.credentials,
        install: decoded.install
      )

    assert {:ok, authority} = HostInstallationOwner.start(host)
    owner = authority.pid
    monitor = Process.monitor(owner)
    assert :ok = :sys.suspend(owner)
    parent = self()

    transfer =
      spawn(fn ->
        receive do: (:activate -> :ok)

        result = HostInstallationAuthority.transfer_to_registry(authority, self())
        send(parent, {:pending_transfer_result, result})
      end)

    assert 1 = :erlang.trace(transfer, true, [:send])
    send(transfer, :activate)

    assert_receive {:trace, ^transfer, :send,
                    {:"$gen_call", _from,
                     {:transfer, _token, :catalog, :registry, ^transfer, _transition, _deadline}},
                    ^owner}

    assert :atomics.get(authority.fence, 1) > 1
    assert :ok = HostInstallationAuthority.close(authority)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert_receive {:pending_transfer_result, {:error, :invalid_host_installation_authority}}
  end

  test "published cross-process transfer detaches the old creator before suspension" do
    parent = self()

    document = %{
      "install" => %{
        "history" => %{
          "source" => "ptc_trace_snapshot",
          "installation_revision" => "history-v1",
          "directory" => "traces"
        }
      }
    }

    creator =
      spawn(fn ->
        {:ok, decoded} = HostConfig.decode(document, "/tmp")

        host =
          struct!(HostConfig,
            path: "/tmp/ptc-host.json",
            directory: "/tmp",
            runtime: decoded.runtime,
            limits: decoded.limits,
            credentials: decoded.credentials,
            install: decoded.install
          )

        {:ok, authority} = HostInstallationOwner.start(host)
        send(parent, {:cross_process_authority, authority})
        receive do: (:hold -> :ok)
      end)

    assert_receive {:cross_process_authority, authority}
    owner = authority.pid

    registry_holder =
      spawn(fn ->
        result = HostInstallationAuthority.transfer_to_registry(authority, self())
        send(parent, {:cross_process_registry, self(), result})
        receive do: (:hold -> :ok)
      end)

    assert_receive {:cross_process_registry, ^registry_holder, {:ok, registry_authority}}
    owner_monitor = Process.monitor(owner)
    creator_monitor = Process.monitor(creator)
    assert :ok = :sys.suspend(owner)
    Process.exit(creator, :kill)
    assert_receive {:DOWN, ^creator_monitor, :process, ^creator, :killed}
    assert Process.alive?(owner)
    assert :ok = :sys.resume(owner)
    assert :ok = HostInstallationAuthority.close(registry_authority)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    send(registry_holder, :hold)
  end

  test "OAuth runtime activation requires and binds a principal context" do
    selected_authority = oauth_authority("selected.example", "selected-oauth")
    unselected_authority = oauth_authority("unselected.example", "unselected-oauth")

    assert {:ok, catalog} =
             custom_catalog(
               authority: selected_authority,
               extra_authority: unselected_authority
             )

    assert {:ok, services} = ProviderRuntimeServices.new()

    assert {:error, :authorization_context_required} =
             InstallationCatalog.runtime_registry(catalog, services)

    assert {:ok, memory} = Memory.start(owner: self())
    assert {:ok, store} = Memory.store(memory)

    parent = self()

    interceptor = fn
      {:claim_principal, "tenant", "principal"}, deadline ->
        send(parent, {:principal_claim_deadline, deadline})
        :delegate

      {:claim_authorities, "tenant", authorities}, deadline ->
        send(parent, {:authority_claim, authorities, deadline})
        :delegate

      _operation, _deadline ->
        :delegate
    end

    assert {:ok, recording_store} =
             MCPOAuthRecordingStore.wrap(store, self(), interceptor: interceptor)

    assert {:ok, services} =
             ProviderRuntimeServices.new(
               oauth_mode:
                 {:context_factory,
                  fn deadline ->
                    send(parent, {:oauth_factory_deadline, deadline})

                    OAuthContext.new(
                      tenant_id: "tenant",
                      principal_id: "principal",
                      store: recording_store,
                      deadline: deadline
                    )
                  end}
             )

    operation_deadline = Deadline.new(1_000)

    assert {:ok, registry} =
             InstallationCatalog.runtime_registry(
               catalog,
               services,
               ["selected"],
               operation_deadline,
               self()
             )

    assert_receive {:oauth_factory_deadline, shared_deadline}
    assert shared_deadline == operation_deadline
    assert_receive {:principal_claim_deadline, ^shared_deadline}

    assert_receive {:authority_claim, claims, ^shared_deadline}

    assert claims == [
             {selected_authority.installation_id, selected_authority.fingerprint}
           ]

    assert Map.keys(registry.builders) == ["selected"]

    limits = Limits.installed_defaults()

    assert {:error, :oauth_runtime_bound} =
             ProviderRegistry.prepare(registry, "selected", %{}, %{
               application_content_digest: String.duplicate("0", 64),
               destination: :workflow,
               owner: self(),
               limits: limits,
               installed_limits: limits
             })

    assert :ok = ProviderRegistry.close(registry)
  end

  test "runtime registry preserves operation deadline expiry" do
    assert {:ok, catalog} = custom_catalog()
    assert {:ok, services} = ProviderRuntimeServices.new()

    expired = Deadline.from_expires_at(System.monotonic_time(:millisecond) - 1)

    assert {:error, :operation_deadline_expired} =
             InstallationCatalog.runtime_registry(
               catalog,
               services,
               ["selected"],
               expired,
               self()
             )
  end

  test "a runtime registry is refused when activation finishes after the deadline" do
    assert {:ok, catalog} = custom_catalog()
    deadline = Deadline.new(50)

    # Activation runs an embedder-supplied callback that cannot be cancelled,
    # because the authority it returns belongs to the process that created it.
    # A slow one must still not yield a usable registry past the deadline.
    activation = fn ->
      wait_until_expired(deadline)
      {:ok, nil}
    end

    assert {:ok, services} = ProviderRuntimeServices.new(activation: activation)

    assert {:error, :operation_deadline_expired} =
             InstallationCatalog.runtime_registry(
               catalog,
               services,
               ["selected"],
               deadline,
               self()
             )
  end

  test "an unbound catalog cancels an activation that never returns" do
    assert {:ok, catalog} = custom_catalog()
    parent = self()

    activation = fn ->
      send(parent, {:activation_entered, self()})
      receive do: (:never -> :never)
    end

    assert {:ok, services} = ProviderRuntimeServices.new(activation: activation)

    # Returning at all is the assertion: this hangs without a bounded worker,
    # and the cancellation keeps its timeout classification.
    assert {:error, :operation_deadline_expired} =
             InstallationCatalog.runtime_registry(
               catalog,
               services,
               ["selected"],
               Deadline.new(150),
               self()
             )

    assert_receive {:activation_entered, worker}, 5_000
    reference = Process.monitor(worker)
    assert_receive {:DOWN, ^reference, :process, ^worker, _reason}, 5_000
  end

  test "an unbound catalog releases an authority its activation did not create" do
    # The generic-authority test below builds its owner inside the activation
    # callback, so creator-monitor teardown would hide a missing release. This
    # one hands back an authority the test process owns.
    assert {:ok, catalog} = custom_catalog()
    assert {:ok, authority} = HostInstallationOwner.start(generic_host())
    owner = authority.pid
    assert Process.alive?(owner)

    assert {:ok, services} = ProviderRuntimeServices.new(activation: fn -> {:ok, authority} end)

    assert {:error, :invalid_provider_registry} =
             InstallationCatalog.runtime_registry(
               catalog,
               services,
               ["selected"],
               Deadline.new(1_000),
               self()
             )

    refute Process.alive?(owner)
  end

  test "an unbound catalog rejects and releases a generic host authority" do
    host = generic_host()
    assert {:ok, catalog} = custom_catalog()
    parent = self()

    activation = fn ->
      {:ok, authority} = HostInstallationOwner.start(host)
      send(parent, {:generic_substitute_owner, authority.pid})
      {:ok, authority}
    end

    assert {:ok, services} = ProviderRuntimeServices.new(activation: activation)

    assert {:error, :invalid_provider_registry} =
             InstallationCatalog.runtime_registry(catalog, services)

    assert_receive {:generic_substitute_owner, owner}
    refute Process.alive?(owner)
  end

  test "OAuth catalog rejects malformed private authority and runtime activation fails closed" do
    assert {:ok, catalog} = custom_catalog(authority: oauth_authority("issuer.example"))
    authority = catalog.authorities["selected"]
    refute Authority.valid?(%{authority | issuer: "not-an-issuer"})

    assert {:error, :invalid_installation_catalog} =
             InstallationCatalog.new(%{
               "selected" => %{
                 descriptor: catalog.descriptors["selected"],
                 implementation: catalog.implementations["selected"],
                 authority: %{authority | issuer: "not-an-issuer"}
               }
             })

    assert {:ok, memory} = Memory.start(owner: self())
    assert {:ok, store} = Memory.store(memory)

    assert {:ok, context} =
             OAuthContext.new(
               tenant_id: "tenant",
               principal_id: "principal",
               store: store,
               deadline: Deadline.new(1_000)
             )

    factory_calls = :atomics.new(1, signed: false)

    assert {:ok, services} =
             ProviderRuntimeServices.new(
               oauth_mode:
                 {:context_factory,
                  fn _deadline ->
                    :atomics.add(factory_calls, 1, 1)
                    {:ok, context}
                  end}
             )

    malformed_catalog = %{catalog | descriptors: []}

    assert {:error, :invalid_provider_registry} =
             InstallationCatalog.runtime_registry(malformed_catalog, services)

    assert :atomics.get(factory_calls, 1) == 0

    assert {:ok, %{"oauth-primary" => _epoch}} =
             Store.claim_authorities(
               store,
               "tenant",
               [{"oauth-primary", "different-fingerprint"}],
               Deadline.new(1_000)
             )
  end

  test "host catalog declares all shipped sources plus static and OAuth MCP without activity" do
    document = %{
      "credentials" => %{
        "token" => %{"literal" => "not-read-during-catalog"},
        "llm-key" => %{"literal" => "not-read-during-catalog"}
      },
      "install" => %{
        "static" => %{
          "source" => "mcp",
          "installation_revision" => "static-v1",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://static.example/mcp",
            "auth" => [%{"scheme" => "bearer", "binding" => "token"}]
          },
          "tools" => %{
            "read" => %{
              "as" => "static.read",
              "effect" => "read",
              "model_visible" => true
            }
          }
        },
        "oauth" => %{
          "source" => "mcp",
          "installation_revision" => "oauth-v1",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://oauth.example/mcp",
            "oauth" => %{
              "installation_id" => "oauth-primary",
              "issuer" => "https://issuer.example",
              "scope_ceiling" => ["read"],
              "default_scopes" => ["read"],
              "client" => %{
                "registration" => "pre_registered",
                "client_id" => "public-client",
                "token_endpoint_auth_method" => "none",
                "grant_types" => ["authorization_code"],
                "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
              }
            }
          },
          "tools" => %{
            "read" => %{"as" => "oauth.read", "effect" => "read"}
          }
        },
        "live" => %{
          "source" => "llm",
          "structured_output_mode" => "unsupported",
          "installation_revision" => "live-v1",
          "model" => "provider:private-selector",
          "credential" => "llm-key"
        },
        "replay" => %{
          "source" => "llm_replay",
          "installation_revision" => "replay-v1",
          "fixtures" => "missing-replay.jsonl"
        },
        "trace" => %{
          "source" => "ptc_trace_snapshot",
          "installation_revision" => "trace-v1",
          "directory" => "missing-trace"
        },
        "inspection" => %{
          "source" => "ptc_inspection_snapshot",
          "installation_revision" => "inspection-v1",
          "directory" => "missing-inspection"
        }
      }
    }

    assert {:ok, decoded} = HostConfig.decode(document, "/definitely/not/read")

    host =
      struct!(HostConfig,
        path: "/definitely/not/read/ptc-host.json",
        directory: "/definitely/not/read",
        runtime: decoded.runtime,
        limits: decoded.limits,
        credentials: decoded.credentials,
        install: decoded.install
      )

    assert {:ok, catalog} = HostInstallation.catalog(host)
    assert {:ok, runtime_services} = HostInstallation.runtime_services(host)
    assert ProviderRuntimeServices.valid?(runtime_services)

    owners_before = host_installation_owners()

    assert {:error, :authorization_context_required} =
             InstallationCatalog.runtime_registry(catalog, runtime_services)

    assert host_installation_owners() == owners_before

    captured_recipes =
      catalog.implementations
      |> Enum.flat_map(fn {_name, implementation} -> Map.values(implementation) end)
      |> Enum.filter(&is_function/1)
      |> Enum.flat_map(fn callback ->
        {:env, environment} = :erlang.fun_info(callback, :env)
        environment
      end)
      |> :erlang.term_to_binary()

    refute captured_recipes =~ "not-read-during-catalog"
    refute :erlang.term_to_binary(catalog) =~ "not-read-during-catalog"

    assert InstallationCatalog.names(catalog) ==
             ~w(inspection live oauth replay static trace)

    assert catalog.implementations["live"].provider_application == :req_llm

    assert catalog.descriptors["static"].authorization_mode == :none
    assert catalog.descriptors["static"].credential_names == ["token"]
    assert catalog.descriptors["static"].connectivity_mode == :acquisition

    assert catalog.authorities["oauth"] == :host_runtime
    assert catalog.descriptors["oauth"].authorization_mode == :oauth
    assert is_binary(catalog.descriptors["oauth"].authority_fingerprint)

    assert catalog.descriptors["oauth"].credential_names == []

    assert catalog.descriptors["live"].connectivity_mode == :probe
    assert catalog.descriptors["live"].probe_effect == :completion
    assert catalog.descriptors["replay"].connectivity_mode == :none
    assert catalog.descriptors["replay"].local_preflight == :audited_local
    assert catalog.descriptors["trace"].provides == [:canonical_trace_snapshot]
    assert catalog.descriptors["trace"].data_class == :normal
    assert catalog.descriptors["trace"].accepts_data == [:normal, :private_inspection]
    assert catalog.descriptors["inspection"].requires == [:canonical_trace_snapshot]
    assert catalog.descriptors["inspection"].data_class == :private_inspection
    assert catalog.descriptors["inspection"].accepts_data == [:normal, :private_inspection]

    invalid_inspection_options =
      catalog.descriptors["inspection"]
      |> Map.from_struct()
      |> Map.delete(:attestation)
      |> Map.put(:data_class, :normal)
      |> Map.to_list()

    assert {:error, :invalid_provider_descriptor} =
             ProviderDescriptor.new(invalid_inspection_options)

    for {name, raw_selection} <- [
          {"static", %{}},
          {"oauth", %{}},
          {"live", %{}},
          {"replay", %{}},
          {"trace", %{}},
          {"inspection", %{}}
        ] do
      descriptor = catalog.descriptors[name]

      assert {:ok, normalized} =
               SelectionRules.normalize(
                 descriptor.selection_rules,
                 raw_selection,
                 catalog.installed_limits
               )

      assert {:ok, ^normalized} =
               HostInstallation.normalize_selection(
                 host.install[name],
                 raw_selection,
                 %{limits: catalog.installed_limits}
               )

      assert {:ok, ^normalized} =
               HostInstallation.normalize_selection(
                 host.install[name],
                 normalized,
                 %{limits: catalog.installed_limits}
               )
    end

    assert {:ok,
            %{
              "allow" => ["static.read"],
              "model_visible" => ["static.read"],
              "timeout_ms" => 5_000,
              "max_result_bytes" => 1_000_000
            }} =
             SelectionRules.normalize(
               catalog.descriptors["static"].selection_rules,
               %{},
               catalog.installed_limits
             )

    public = InstallationCatalog.public_installations(catalog)
    encoded = Jason.encode!(public)
    refute encoded =~ "private-selector"
    refute encoded =~ "issuer.example"
    refute encoded =~ catalog.descriptors["oauth"].authority_fingerprint
  end

  test "provider-free preparation computes the exact effective identity without activity", %{
    tmp_dir: directory
  } do
    manifest = manifest()
    documents = documents(manifest)
    application = write_application(directory, "provider-free", documents)

    assert {:ok, directory_request} =
             ApplicationPackage.request_directory(application, result_projection: :json)

    assert {:ok, memory_request} =
             ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    assert {:ok, catalog} = InstallationCatalog.new()

    assert {:ok, %PreparedRun{} = from_directory} =
             RunCoordinator.prepare(directory_request, catalog)

    assert {:ok, %PreparedRun{} = from_memory} =
             RunCoordinator.prepare(memory_request, catalog)

    assert from_directory.effective_application_digest ==
             from_memory.effective_application_digest

    assert from_directory.effective_application_projection ==
             from_memory.effective_application_projection

    assert "sha256:" <> <<_::binary-size(64)>> =
             from_directory.effective_application_digest

    projection = from_directory.effective_application_projection
    assert projection["providers"] == %{"workflow" => [], "mission" => []}
    assert projection["input_authority_class"] == "normal"
    assert projection["effective_event_policy"] == "normal"
    assert projection["inspection_capture_enabled"] == false
    assert projection["result_projection"] == "json"
    assert projection["limits"]["provider_cleanup_timeout_ms"] == 5_000
    assert projection["limits"]["selection_validation_timeout_ms"] == 5_000
    refute Map.has_key?(projection["limits"], "doctor_connectivity_timeout_ms")
    assert ProviderActivity.value(from_directory.provider_activity) == false

    assert {:ok, encoded} = TypedCanonicalJSON.encode(projection)

    expected_digest =
      :crypto.hash(
        :sha256,
        [
          <<"ptc.effective-application.v2", 0>>,
          <<byte_size(encoded)::unsigned-big-64>>,
          encoded
        ]
      )
      |> Base.encode16(case: :lower)
      |> then(&("sha256:" <> &1))

    assert from_directory.effective_application_digest == expected_digest

    assert :ok = PreparedRun.close(from_directory)
    assert :ok = PreparedRun.close(from_memory)
  end

  test "input value and form are excluded while authority and execution policy change identity" do
    inline_a = put_in(manifest(), ["input"], %{"value" => %{"secret" => "a"}})
    inline_b = put_in(manifest(), ["input"], %{"value" => %{"secret" => "b"}})
    path_manifest = put_in(manifest(), ["input"], %{"path" => "private-input.json"})

    path_documents =
      Map.put(documents(path_manifest), "private-input.json", ~s({"different":true}))

    assert {:ok, inline_a_request} =
             ApplicationPackage.request_memory("ptc.json", documents(inline_a),
               result_projection: :json
             )

    assert {:ok, inline_b_request} =
             ApplicationPackage.request_memory("ptc.json", documents(inline_b),
               result_projection: :json
             )

    assert {:ok, path_request} =
             ApplicationPackage.request_memory("ptc.json", path_documents,
               result_projection: :json
             )

    assert inline_a_request.package.application_content_digest ==
             inline_b_request.package.application_content_digest

    assert inline_a_request.package.application_content_digest ==
             path_request.package.application_content_digest

    assert {:ok, catalog} = InstallationCatalog.new()
    assert {:ok, inline_a_prepared} = RunCoordinator.prepare(inline_a_request, catalog)
    assert {:ok, inline_b_prepared} = RunCoordinator.prepare(inline_b_request, catalog)
    assert {:ok, path_prepared} = RunCoordinator.prepare(path_request, catalog)

    assert inline_a_prepared.effective_application_digest ==
             inline_b_prepared.effective_application_digest

    assert inline_a_prepared.effective_application_digest ==
             path_prepared.effective_application_digest

    assert {:ok, private_request} =
             ApplicationPackage.request_memory("ptc.json", documents(inline_a),
               input_authority: :private,
               result_projection: :json
             )

    assert {:ok, private_prepared} = RunCoordinator.prepare(private_request, catalog)
    assert private_prepared.effective_event_policy == :private

    refute private_prepared.effective_application_digest ==
             inline_a_prepared.effective_application_digest

    assert {:ok, inspected_request} =
             ApplicationPackage.request_memory("ptc.json", documents(inline_a),
               inspection_capture: true,
               result_projection: :json
             )

    assert {:ok, native_request} =
             ApplicationPackage.request_memory("ptc.json", documents(inline_a),
               result_projection: :native
             )

    assert {:ok, inspected} = RunCoordinator.prepare(inspected_request, catalog)
    assert {:ok, native} = RunCoordinator.prepare(native_request, catalog)

    refute inspected.effective_application_digest ==
             inline_a_prepared.effective_application_digest

    refute native.effective_application_digest ==
             inline_a_prepared.effective_application_digest

    for prepared <- [
          inline_a_prepared,
          inline_b_prepared,
          path_prepared,
          private_prepared,
          inspected,
          native
        ] do
      assert :ok = PreparedRun.close(prepared)
    end
  end

  test "effective identity varies only with selected public declaration behavior" do
    manifest =
      manifest()
      |> put_in(
        ["providers"],
        %{
          "workflow" => [%{"name" => "selected", "config" => %{"mode" => "a"}}],
          "mission" => []
        }
      )

    assert {:ok, base_catalog} = custom_catalog()
    assert {:ok, base} = prepare_identity(manifest, base_catalog)

    assert base.effective_application_projection["providers"]["workflow"] == [
             %{
               "name" => "selected",
               "source" => "custom",
               "installation_revision" => "custom-v1",
               "data_class" => "normal",
               "accepts_data" => ["normal"],
               "authorization_mode" => "none",
               "config" => %{"mode" => "a"}
             }
           ]

    assert {:ok, revised_catalog} = custom_catalog(installation_revision: "custom-v2")
    assert {:ok, revised} = prepare_identity(manifest, revised_catalog)
    refute revised.effective_application_digest == base.effective_application_digest

    assert {:ok, private_catalog} =
             custom_catalog(
               data_class: :private_inspection,
               accepts_data: [:normal, :private_inspection]
             )

    assert {:ok, private} = prepare_identity(manifest, private_catalog)
    assert private.effective_event_policy == :private
    refute private.effective_application_digest == base.effective_application_digest

    changed_selection =
      put_in(manifest, ["providers", "workflow", Access.at(0), "config"], %{
        "mode" => "b"
      })

    assert {:ok, selection_b} = prepare_identity(changed_selection, base_catalog)
    refute selection_b.effective_application_digest == base.effective_application_digest

    assert {:ok, with_unselected_v1} =
             custom_catalog(extra_revision: "extra-v1")

    assert {:ok, with_unselected_v2} =
             custom_catalog(extra_revision: "extra-v2")

    assert {:ok, unselected_v1} = prepare_identity(manifest, with_unselected_v1)
    assert {:ok, unselected_v2} = prepare_identity(manifest, with_unselected_v2)

    assert unselected_v1.effective_application_digest ==
             unselected_v2.effective_application_digest

    for prepared <- [base, revised, private, selection_b, unselected_v1, unselected_v2] do
      assert ProviderActivity.value(prepared.provider_activity) == false
      assert :ok = PreparedRun.close(prepared)
    end
  end

  test "authorization mode changes identity while private OAuth authority does not" do
    manifest =
      manifest()
      |> put_in(
        ["providers"],
        %{
          "workflow" => [%{"name" => "selected", "config" => %{"mode" => "a"}}],
          "mission" => []
        }
      )

    assert {:ok, none_catalog} = custom_catalog()
    assert {:ok, oauth_a_catalog} = custom_catalog(authority: oauth_authority("issuer-a.example"))
    assert {:ok, oauth_b_catalog} = custom_catalog(authority: oauth_authority("issuer-b.example"))

    assert {:ok, none} = prepare_identity(manifest, none_catalog)
    assert {:ok, oauth_a} = prepare_identity(manifest, oauth_a_catalog)
    assert {:ok, oauth_b} = prepare_identity(manifest, oauth_b_catalog)

    refute none.effective_application_digest == oauth_a.effective_application_digest
    assert oauth_a.effective_application_digest == oauth_b.effective_application_digest

    encoded = Jason.encode!(oauth_a.effective_application_projection)
    assert encoded =~ ~s("authorization_mode":"oauth")
    refute encoded =~ "issuer-a.example"
    refute encoded =~ oauth_a_catalog.authorities["selected"].fingerprint

    for prepared <- [none, oauth_a, oauth_b], do: PreparedRun.close(prepared)
  end

  test "active custom selection remains inert and validate reports it as unverifiable" do
    assert {:ok, catalog} = custom_catalog(selection_validation: :active)

    manifest =
      manifest()
      |> put_in(
        ["providers"],
        %{
          "workflow" => [%{"name" => "selected", "config" => %{"mode" => "a"}}],
          "mission" => []
        }
      )

    assert {:ok, prepared} = prepare_identity(manifest, catalog)
    assert ProviderActivity.value(prepared.provider_activity) == false

    assert {:error, {:selection_unverifiable, "selected", %{destination: :workflow, index: 0}}} =
             RunCoordinator.validation_result(prepared)

    assert :ok = PreparedRun.close(prepared)
  end

  test "prepared-run sealing recomputes active state and catalog correlation" do
    assert {:ok, active_catalog} = custom_catalog(selection_validation: :active)
    assert {:ok, other_catalog} = custom_catalog(installation_revision: "custom-v2")

    selected_manifest =
      put_in(manifest(), ["providers"], %{
        "workflow" => [%{"name" => "selected", "config" => %{"mode" => "a"}}],
        "mission" => []
      })

    assert {:ok, prepared} = prepare_identity(selected_manifest, active_catalog)

    forged_metadata =
      prepared
      |> Map.take([
        :provider_declarations,
        :effective_data_class,
        :effective_flow,
        :effective_event_policy,
        :effective_application_projection,
        :effective_application_digest,
        :installation_config_digests,
        :post_selection_context
      ])
      |> update_in([:provider_declarations, Access.at(0), :validation_state], fn _state ->
        :declarative
      end)

    assert {:error, :invalid_prepared_run} =
             ProviderActivity.start_owned(fn activity ->
               PreparedRun.new(
                 prepared.request,
                 prepared.workflow_bundle,
                 prepared.mission_bundles,
                 prepared.entry_source,
                 activity,
                 active_catalog,
                 forged_metadata
               )
             end)

    assert {:ok, run_ref} = CommandRunRef.generate()
    assert {:ok, runtime_services} = ProviderRuntimeServices.new()

    assert {:error, :invalid_command_preparation} =
             CommandPreparation.new(
               :validate,
               run_ref,
               prepared,
               other_catalog,
               runtime_services,
               false,
               nil,
               {%{}, []}
             )

    assert :ok = PreparedRun.close(prepared)
  end

  test "prepared-run sealing recomputes classifications and rejects open context fields" do
    private_manifest = manifest()
    documents = documents(private_manifest)

    assert {:ok, request} =
             ApplicationPackage.request_memory("ptc.json", documents,
               input_authority: :private,
               result_projection: :json
             )

    assert {:ok, catalog} = InstallationCatalog.new()
    assert {:ok, prepared} = RunCoordinator.prepare(request, catalog)

    assert {:ok, forged_identity} =
             EffectiveApplication.build(
               request,
               prepared.workflow_bundle,
               prepared.mission_bundles,
               %{workflow: [], mission: []},
               :normal
             )

    forged_context = %{
      application_content_digest: request.package.application_content_digest,
      effective_application_digest: forged_identity.digest,
      bundle_hashes: %{workflow: prepared.workflow_bundle.hash, mission: nil},
      input_authority_class: :private,
      limits: request.package.limits,
      effective_data_class: :normal,
      effective_flow: :normal,
      effective_event_policy: :normal
    }

    forged_metadata = %{
      provider_declarations: [],
      effective_data_class: :normal,
      effective_flow: :normal,
      effective_event_policy: :normal,
      effective_application_projection: forged_identity.projection,
      effective_application_digest: forged_identity.digest,
      post_selection_context: forged_context
    }

    assert {:error, :invalid_prepared_run} =
             ProviderActivity.start_owned(fn activity ->
               PreparedRun.new(
                 request,
                 prepared.workflow_bundle,
                 prepared.mission_bundles,
                 prepared.entry_source,
                 activity,
                 catalog,
                 forged_metadata
               )
             end)

    open_context_metadata = %{
      forged_metadata
      | effective_data_class: prepared.effective_data_class,
        effective_flow: prepared.effective_flow,
        effective_event_policy: prepared.effective_event_policy,
        effective_application_projection: prepared.effective_application_projection,
        effective_application_digest: prepared.effective_application_digest,
        post_selection_context: Map.put(prepared.post_selection_context, :endpoint, "secret")
    }

    assert {:error, :invalid_prepared_run} =
             ProviderActivity.start_owned(fn activity ->
               PreparedRun.new(
                 request,
                 prepared.workflow_bundle,
                 prepared.mission_bundles,
                 prepared.entry_source,
                 activity,
                 catalog,
                 open_context_metadata
               )
             end)

    assert :ok = PreparedRun.close(prepared)
  end

  test "provider dependency validation rejects cycles with a declaration diagnostic" do
    assert {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    registrations =
      Map.new(
        [
          {"alpha", [:beta_service], [:alpha_service]},
          {"beta", [:alpha_service], [:beta_service]}
        ],
        fn {name, requires, provides} ->
          {:ok, descriptor} =
            ProviderDescriptor.new(
              source: :custom,
              installation_revision: name <> "-v1",
              credential_names: [],
              authorization_mode: :none,
              data_class: :normal,
              accepts_data: [:normal],
              requires: requires,
              provides: provides,
              destinations: [:mission],
              workflow_llm?: false,
              connectivity_mode: :none,
              probe_effect: nil,
              selection_validation: :declarative,
              selection_rules: rules,
              authority_fingerprint: nil,
              local_preflight: :none
            )

          {name,
           %{
             descriptor: descriptor,
             authority: nil,
             implementation: %{builder: fn _selection, _context -> {:error, :inactive} end}
           }}
        end
      )

    assert {:ok, catalog} = InstallationCatalog.new(registrations)

    cyclic_manifest =
      put_in(manifest(), ["providers"], %{
        "workflow" => [],
        "mission" => [%{"name" => "alpha"}, %{"name" => "beta"}]
      })

    assert {:error, diagnostic} = prepare_identity(cyclic_manifest, catalog)
    assert diagnostic.phase == :provider_declaration
    assert diagnostic.code == :dependency_invalid
    assert diagnostic.subject.name == "alpha"
    assert diagnostic.subject.operation == :declaration
    assert diagnostic.subject.occurrence == nil
  end

  test "dependency diagnostics identify the provider requiring an invalid service" do
    assert {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    registrations = %{
      "unrelated" => dependency_registration(rules, "unrelated", [], []),
      "consumer" => dependency_registration(rules, "consumer", [:missing_service], [])
    }

    assert {:ok, catalog} = InstallationCatalog.new(registrations)

    invalid_manifest =
      put_in(manifest(), ["providers"], %{
        "workflow" => [],
        "mission" => [%{"name" => "unrelated"}, %{"name" => "consumer"}]
      })

    assert {:error, diagnostic} = prepare_identity(invalid_manifest, catalog)
    assert diagnostic.phase == :provider_declaration
    assert diagnostic.code == :dependency_invalid
    assert diagnostic.subject.name == "consumer"
    assert diagnostic.subject.operation == :declaration
    assert diagnostic.subject.occurrence == nil
  end

  test "inspection rejects two selected providers for the canonical trace service", %{
    tmp_dir: dir
  } do
    document = %{
      "install" => %{
        "normal-trace" => %{
          "source" => "ptc_trace_snapshot",
          "installation_revision" => "normal-v1",
          "directory" => "traces"
        },
        "private-trace" => %{
          "source" => "ptc_private_trace_snapshot",
          "installation_revision" => "private-v1",
          "directory" => "traces"
        },
        "inspection" => %{
          "source" => "ptc_inspection_snapshot",
          "installation_revision" => "inspection-v1",
          "directory" => "inspection"
        }
      }
    }

    host_path = Path.join(dir, "host.json")
    File.write!(host_path, Jason.encode!(document))
    assert {:ok, host} = HostConfig.load(host_path)
    assert {:ok, catalog} = HostInstallation.catalog(host)

    invalid_manifest =
      put_in(manifest(), ["providers"], %{
        "workflow" => [],
        "mission" => [
          %{"name" => "normal-trace"},
          %{"name" => "private-trace"},
          %{"name" => "inspection"}
        ]
      })

    assert {:error, diagnostic} = prepare_identity(invalid_manifest, catalog)
    assert diagnostic.phase == :provider_declaration
    assert diagnostic.code == :dependency_invalid
    assert diagnostic.subject.name == "inspection"
  end

  test "provider dependency validation remains bounded for a dense near-limit DAG" do
    assert {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    services = @dense_services

    registrations =
      services
      |> Enum.with_index(1)
      |> Map.new(fn {service, index} ->
        name = "node-" <> String.pad_leading(Integer.to_string(index), 2, "0")

        {:ok, descriptor} =
          ProviderDescriptor.new(
            source: :custom,
            installation_revision: name <> "-v1",
            credential_names: [],
            authorization_mode: :none,
            data_class: :normal,
            accepts_data: [:normal],
            requires: services |> Enum.take(index - 1) |> Enum.sort(),
            provides: [service],
            destinations: [:mission],
            workflow_llm?: false,
            connectivity_mode: :none,
            probe_effect: nil,
            selection_validation: :declarative,
            selection_rules: rules,
            authority_fingerprint: nil,
            local_preflight: :none
          )

        {name,
         %{
           descriptor: descriptor,
           authority: nil,
           implementation: %{builder: fn _selection, _context -> {:error, :inactive} end}
         }}
      end)

    assert {:ok, catalog} = InstallationCatalog.new(registrations)

    dense_manifest =
      put_in(manifest(), ["providers"], %{
        "workflow" => [],
        "mission" =>
          Enum.map(1..32, fn index ->
            %{"name" => "node-" <> String.pad_leading(Integer.to_string(index), 2, "0")}
          end)
      })

    assert {:ok, prepared} = prepare_identity(dense_manifest, catalog)
    assert :ok = PreparedRun.close(prepared)
  end

  test "command validation rejects an empty allow list for a write-bearing MCP", %{
    tmp_dir: directory
  } do
    host_document = %{
      "install" => %{
        "remote" => %{
          "source" => "mcp",
          "installation_revision" => "remote-v1",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://example.com/mcp"
          },
          "tools" => %{
            "write" => %{"as" => "remote.write", "effect" => "write"}
          }
        }
      }
    }

    host_path = Path.join(directory, "ptc-host.json")
    File.write!(host_path, Jason.encode!(host_document))

    selected_manifest =
      put_in(manifest(), ["providers"], %{
        "workflow" => [],
        "mission" => [%{"name" => "remote", "config" => %{"allow" => []}}]
      })

    application = write_application(directory, "empty-write-allow", documents(selected_manifest))

    assert {:error, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["validate", application, "--host-config", host_path])

    assert outcome.exit_status == 3
    assert outcome.envelope["error"]["phase"] == "provider_declaration"
    assert outcome.envelope["error"]["code"] == "selection_invalid"

    assert outcome.envelope["error"]["message"] ==
             "the provider selection field allow is invalid"

    omitted_manifest =
      put_in(manifest(), ["providers"], %{
        "workflow" => [],
        "mission" => [%{"name" => "remote"}]
      })

    omitted_application =
      write_application(directory, "omitted-write-allow", documents(omitted_manifest))

    assert {:error, %CommandOutcome{} = omitted_outcome} =
             CommandEngine.prepare(["validate", omitted_application, "--host-config", host_path])

    assert omitted_outcome.envelope["error"]["message"] ==
             "the provider selection field allow is required because the installation maps a write"
  end

  test "command validation accepts a model_visible subset of allow and names remaining selection rules",
       %{tmp_dir: directory} do
    host_document = %{
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "workspace-v1",
          "transport" => %{
            "type" => "stdio",
            "command" => "/bin/echo",
            "args" => ["."]
          },
          "tools" => %{
            "read_text_file" => %{"as" => "workspace.read", "effect" => "read"},
            "write_file" => %{"as" => "workspace.write", "effect" => "write"}
          }
        }
      }
    }

    host_path = Path.join(directory, "ptc-host.json")
    File.write!(host_path, Jason.encode!(host_document))

    selected = fn config ->
      put_in(manifest(), ["providers"], %{
        "workflow" => [],
        "mission" => [%{"name" => "workspace", "config" => config}]
      })
    end

    documented =
      selected.(%{
        "allow" => ["workspace.read", "workspace.write"],
        "model_visible" => ["workspace.read"]
      })

    application = write_application(directory, "model-visible-documented", documents(documented))

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["validate", application, "--host-config", host_path])

    assert outcome.exit_status == 0

    uninstalled =
      selected.(%{
        "allow" => ["workspace.read", "workspace.write"],
        "model_visible" => ["nope.x"]
      })

    uninstalled_path =
      write_application(directory, "model-visible-uninstalled", documents(uninstalled))

    assert {:error, %CommandOutcome{} = uninstalled_outcome} =
             CommandEngine.prepare(["validate", uninstalled_path, "--host-config", host_path])

    assert uninstalled_outcome.envelope["error"]["code"] == "selection_invalid"

    assert uninstalled_outcome.envelope["error"]["message"] ==
             "the provider selection field model_visible contains a name outside its allowed set"

    assert uninstalled_outcome.envelope["error"]["subject"] == %{
             "kind" => "provider",
             "name" => "workspace",
             "operation" => "selection",
             "occurrence" => %{"destination" => "mission", "index" => 0}
           }

    outside_allow =
      selected.(%{
        "allow" => ["workspace.read"],
        "model_visible" => ["workspace.write"]
      })

    outside_path =
      write_application(directory, "model-visible-outside-allow", documents(outside_allow))

    assert {:error, %CommandOutcome{} = outside_outcome} =
             CommandEngine.prepare(["validate", outside_path, "--host-config", host_path])

    assert outside_outcome.envelope["error"]["message"] ==
             "the provider selection field model_visible must be a subset of allow"
  end

  test "successful validate returns the exact digest envelope without provider activity", %{
    tmp_dir: directory
  } do
    application = write_application(directory, "validate-success", documents(manifest()))

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["validate", application])

    assert outcome.exit_status == 0
    assert outcome.envelope["status"] == "ok"
    assert outcome.envelope["command"] == "validate"

    assert outcome.envelope["result"] == %{
             "application_content_digest" =>
               outcome.envelope["result"]["application_content_digest"],
             "effective_application_digest" =>
               outcome.envelope["result"]["effective_application_digest"],
             "installation_config_digests" => %{},
             "workflow_bundle_hash" => outcome.envelope["result"]["workflow_bundle_hash"],
             "mission_bundle_hashes" => %{},
             "mission_grants" => %{},
             "provider_activity" => false
           }
  end

  test "successful validate summarizes per-mission data, exports, and providers", %{
    tmp_dir: directory
  } do
    manifest =
      manifest()
      |> Map.put("missions", %{
        "intake" => %{
          "components" => [
            %{"id" => "intake", "path" => "intake.clj"},
            %{"id" => "intake-internal", "path" => "intake-internal.clj"}
          ],
          "data" => %{"customer" => %{"id" => "c1"}},
          "providers" => []
        }
      })

    application =
      write_application(directory, "validate-authority", %{
        "ptc.json" => Jason.encode!(manifest),
        "main.clj" => "(ns app) (defn run [input] (return input))",
        "intake.clj" => """
        (ns intake "Intake." {:visibility :prompt})
        (defn summarize "Summarize." [value] value)
        """,
        "intake-internal.clj" => """
        (ns intake.internal "Intake internals." {:visibility :discoverable})
        (defn normalize "Normalize." [value] value)
        """
      })

    assert {:ok, %CommandOutcome{} = outcome} =
             CommandEngine.prepare(["validate", application])

    assert outcome.exit_status == 0

    assert outcome.envelope["result"]["mission_grants"] == %{
             "intake" => %{
               "data" => ["data/customer"],
               "exports" => ["intake.internal/normalize", "intake/summarize"],
               "providers" => []
             }
           }

    assert Map.keys(outcome.envelope["result"]["mission_bundle_hashes"]) == ["intake"]
  end

  defp manifest, do: TestHelpers.valid_manifest()

  defp documents(manifest) do
    %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [input] (return input))"
    }
  end

  defp prepare_identity(manifest, catalog, opts \\ []) do
    with {:ok, request} <-
           ApplicationPackage.request_memory(
             "ptc.json",
             documents(manifest),
             Keyword.put_new(opts, :result_projection, :json)
           ) do
      RunCoordinator.prepare(request, catalog)
    end
  end

  defp custom_catalog(overrides \\ []) do
    {:ok, rules} =
      SelectionRules.new(
        fields: %{
          "mode" => %{
            type: :string,
            input: true,
            default: "a",
            members: "modes"
          }
        },
        cross_rules: [],
        named_sets: %{"modes" => ["a", "b"]}
      )

    authority = Keyword.get(overrides, :authority)
    selection_validation = Keyword.get(overrides, :selection_validation, :declarative)

    descriptor_options = [
      source: :custom,
      installation_revision: Keyword.get(overrides, :installation_revision, "custom-v1"),
      credential_names: [],
      authorization_mode: if(authority, do: :oauth, else: :none),
      data_class: Keyword.get(overrides, :data_class, :normal),
      accepts_data: Keyword.get(overrides, :accepts_data, [:normal]),
      requires: [],
      provides: [],
      destinations: [:workflow],
      workflow_llm?: false,
      connectivity_mode: :none,
      probe_effect: nil,
      selection_validation: selection_validation,
      selection_rules: rules,
      authority_fingerprint: if(authority, do: authority.fingerprint, else: nil),
      local_preflight: :unverified
    ]

    with {:ok, descriptor} <- ProviderDescriptor.new(descriptor_options),
         registrations <-
           %{
             "selected" => %{
               descriptor: descriptor,
               authority: authority,
               implementation:
                 %{
                   builder: fn _selection, _context -> {:error, :inactive_provider} end,
                   local_preflight: fn _selection, _context, _services -> :ok end
                 }
                 |> maybe_oauth_builder(authority)
                 |> maybe_active_validator(selection_validation)
             }
           }
           |> maybe_extra_oauth_registration(
             rules,
             Keyword.get(overrides, :extra_authority)
           )
           |> maybe_extra_registration(rules, Keyword.get(overrides, :extra_revision)) do
      InstallationCatalog.new(registrations)
    end
  end

  defp maybe_active_validator(implementation, :active),
    do: Map.put(implementation, :selection_validator, fn _selection, _context -> :ok end)

  defp maybe_active_validator(implementation, :declarative), do: implementation

  defp maybe_oauth_builder(implementation, nil), do: implementation

  defp maybe_oauth_builder(implementation, %Authority{}),
    do:
      Map.put(
        implementation,
        :oauth_builder,
        fn _selection, _context, _runtime -> {:error, :oauth_runtime_bound} end
      )

  defp maybe_extra_oauth_registration(registrations, _rules, nil), do: registrations

  defp maybe_extra_oauth_registration(registrations, rules, %Authority{} = authority) do
    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: "unselected-oauth-v1",
        credential_names: [],
        authorization_mode: :oauth,
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
        authority_fingerprint: authority.fingerprint,
        local_preflight: :unverified
      )

    Map.put(registrations, "unselected-oauth", %{
      descriptor: descriptor,
      authority: authority,
      implementation: %{
        builder: fn _selection, _context -> {:error, :inactive_provider} end,
        oauth_builder: fn _selection, _context, _runtime ->
          {:error, :unselected_oauth_runtime_bound}
        end,
        local_preflight: fn _selection, _context, _services -> :ok end
      }
    })
  end

  defp maybe_extra_registration(registrations, _rules, nil), do: registrations

  defp maybe_extra_registration(registrations, rules, revision) do
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
        destinations: [:mission],
        workflow_llm?: false,
        connectivity_mode: :none,
        probe_effect: nil,
        selection_validation: :declarative,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    Map.put(registrations, "unselected", %{
      descriptor: descriptor,
      authority: nil,
      implementation: %{builder: fn _selection, _context -> {:error, :inactive_provider} end}
    })
  end

  defp dependency_registration(rules, name, requires, provides) do
    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: name <> "-v1",
        credential_names: [],
        authorization_mode: :none,
        data_class: :normal,
        accepts_data: [:normal],
        requires: requires,
        provides: provides,
        destinations: [:mission],
        workflow_llm?: false,
        connectivity_mode: :none,
        probe_effect: nil,
        selection_validation: :declarative,
        selection_rules: rules,
        authority_fingerprint: nil,
        local_preflight: :none
      )

    %{
      descriptor: descriptor,
      authority: nil,
      implementation: %{builder: fn _selection, _context -> {:error, :inactive} end}
    }
  end

  defp oauth_authority(issuer_host, installation_id \\ "oauth-primary") do
    {:ok, decoded} =
      HostConfig.decode(oauth_host_document(issuer_host, installation_id), "/tmp")

    decoded.install["oauth"].transport.oauth
  end

  defp oauth_host_document(issuer_host, installation_id) do
    %{
      "install" => %{
        "oauth" => %{
          "source" => "mcp",
          "installation_revision" => "oauth-v1",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://mcp.example/mcp",
            "oauth" => %{
              "installation_id" => installation_id,
              "issuer" => "https://" <> issuer_host,
              "scope_ceiling" => ["read"],
              "default_scopes" => ["read"],
              "client" => %{
                "registration" => "pre_registered",
                "client_id" => "public-client",
                "token_endpoint_auth_method" => "none",
                "grant_types" => ["authorization_code"],
                "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
              }
            }
          },
          "tools" => %{"read" => %{"as" => "oauth.read", "effect" => "read"}}
        }
      }
    }
  end

  defp write_application(directory, name, documents) do
    root = Path.join(directory, name)
    File.mkdir_p!(root)

    Enum.each(documents, fn {name, bytes} ->
      File.write!(Path.join(root, name), bytes)
    end)

    Path.join(root, "ptc.json")
  end

  # Scanning `Process.list/0` for the authority marker alone reports every
  # owner in the VM, and this case is `async: true` beside a dozen other files
  # that build host installations. A concurrent case starting an owner between
  # the two calls that bracket an assertion made it fail on an unrelated pid.
  # `HostInstallationOwner.start/1` goes through `GenServer.start/3`, so
  # `proc_lib` records the creating process in `$ancestors`; keeping only our
  # own descendants makes the count a property of this test rather than of the
  # whole suite.
  defp host_installation_owners do
    marker = {PtcRunner.Kernel.HostInstallationOwner, :authority}
    creator = self()

    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          List.keymember?(dictionary, marker, 0) and
            creator in ancestors(dictionary)

        nil ->
          false
      end
    end)
    |> MapSet.new()
  end

  defp ancestors(dictionary) do
    case List.keyfind(dictionary, :"$ancestors", 0) do
      {_key, ancestors} when is_list(ancestors) -> ancestors
      _other -> []
    end
  end

  defp wait_until_expired(deadline) do
    if Deadline.expired?(deadline) do
      :ok
    else
      :erlang.yield()
      wait_until_expired(deadline)
    end
  end

  defp generic_host do
    {:ok, decoded} =
      HostConfig.decode(
        %{
          "install" => %{
            "selected" => %{
              "source" => "ptc_trace_snapshot",
              "installation_revision" => "selected-v1",
              "directory" => "traces"
            }
          }
        },
        "/tmp"
      )

    struct!(HostConfig,
      path: "/tmp/ptc-host.json",
      directory: "/tmp",
      runtime: decoded.runtime,
      limits: decoded.limits,
      credentials: decoded.credentials,
      install: decoded.install
    )
  end
end
