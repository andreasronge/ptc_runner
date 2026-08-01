defmodule PtcRunner.Kernel.ProviderDeclarationTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandPreparation
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.EffectiveApplication
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.HostInstallationAuthority
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
  alias PtcRunner.Kernel.ProviderSnapshot
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules
  alias PtcRunner.Kernel.TypedCanonicalJSON

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
    probe = fn _selection, _context -> :ok end

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

        assert {:ok, catalog} = HostInstallation.catalog(host)
        send(parent, {:catalog_owner, catalog.owner.pid})
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
    assert {:ok, registry} = InstallationCatalog.runtime_registry(catalog)
    registry_owner = registry.authority_owner.pid
    assert Process.alive?(registry_owner)
    assert {:error, :invalid_provider_registry} = InstallationCatalog.runtime_registry(catalog)
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

    assert {:ok, catalog} = HostInstallation.catalog(host)
    owner = catalog.owner.pid
    monitor = Process.monitor(owner)
    assert true = :erlang.suspend_process(owner)
    assert :ok = InstallationCatalog.close(catalog)
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

    assert {:ok, catalog} = HostInstallation.catalog(host)
    owner = catalog.owner.pid
    assert :ok = :sys.suspend(owner)

    transfer = Task.async(fn -> InstallationCatalog.runtime_registry(catalog) end)

    assert Task.yield(transfer, 1_250) ==
             {:ok, {:error, :invalid_provider_registry}}

    monitor = Process.monitor(owner)
    assert :ok = :sys.resume(owner)
    assert :ok = InstallationCatalog.close(catalog)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "catalog close cancels a pending transfer before forcing suspended cleanup" do
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

    assert {:ok, catalog} = HostInstallation.catalog(host)
    owner = catalog.owner.pid
    monitor = Process.monitor(owner)
    assert :ok = :sys.suspend(owner)
    parent = self()

    transfer =
      spawn(fn ->
        receive do: (:activate -> :ok)
        send(parent, {:pending_transfer_result, InstallationCatalog.runtime_registry(catalog)})
      end)

    assert 1 = :erlang.trace(transfer, true, [:send])
    send(transfer, :activate)

    assert_receive {:trace, ^transfer, :send,
                    {:"$gen_call", _from,
                     {:transfer, _token, :catalog, :registry, ^transfer, _transition, _deadline}},
                    ^owner}

    assert :atomics.get(catalog.owner.fence, 1) > 1
    assert :ok = InstallationCatalog.close(catalog)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert_receive {:pending_transfer_result, {:error, :invalid_provider_registry}}
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

        {:ok, catalog} = HostInstallation.catalog(host)
        send(parent, {:cross_process_catalog, catalog})
        receive do: (:hold -> :ok)
      end)

    assert_receive {:cross_process_catalog, catalog}

    registry_owner = catalog.owner.pid

    registry_holder =
      spawn(fn ->
        result = InstallationCatalog.runtime_registry(catalog)
        send(parent, {:cross_process_registry, self(), result})
        receive do: (:hold -> :ok)
      end)

    assert_receive {:cross_process_registry, ^registry_holder, {:ok, registry}}
    owner_monitor = Process.monitor(registry_owner)
    creator_monitor = Process.monitor(creator)
    assert :ok = :sys.suspend(registry_owner)
    Process.exit(creator, :kill)
    assert_receive {:DOWN, ^creator_monitor, :process, ^creator, :killed}
    assert Process.alive?(registry_owner)
    assert :ok = :sys.resume(registry_owner)
    assert :ok = ProviderRegistry.close(registry)
    assert_receive {:DOWN, ^owner_monitor, :process, ^registry_owner, :normal}
    send(registry_holder, :hold)
  end

  test "runtime registry construction rolls back transferred host authority on exceptions" do
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

    assert {:ok, catalog} = HostInstallation.catalog(host)
    owner = catalog.owner.pid
    monitor = Process.monitor(owner)
    storage_key = {Attestation, PtcRunner.Kernel.HostInstallationAuthority}
    previous_key = :persistent_term.get(storage_key, :missing)

    on_exit(fn ->
      case previous_key do
        :missing -> :persistent_term.erase(storage_key)
        key -> :persistent_term.put(storage_key, key)
      end
    end)

    assert :ok = :sys.suspend(owner)
    parent = self()

    worker =
      spawn(fn ->
        receive do: (:activate -> :ok)

        result =
          try do
            InstallationCatalog.runtime_registry(catalog)
          rescue
            exception -> {:raised, exception}
          catch
            kind, reason -> {:raised, {kind, reason}}
          end

        send(parent, {:runtime_registry_result, result})
      end)

    assert 1 = :erlang.trace(worker, true, [:send])
    send(worker, :activate)

    assert_receive {:trace, ^worker, :send,
                    {:"$gen_call", _from,
                     {:transfer, _token, :catalog, :registry, ^worker, _transition, _deadline}},
                    ^owner}

    :persistent_term.put(storage_key, :invalid_hmac_key)
    assert :ok = :sys.resume(owner)
    assert_receive {:runtime_registry_result, {:raised, _reason}}, 1_000

    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "OAuth runtime activation requires and binds a principal context" do
    assert {:ok, catalog} = custom_catalog(authority: oauth_authority("issuer.example"))

    assert {:error, :authorization_context_required} =
             InstallationCatalog.runtime_registry(catalog)

    assert {:ok, memory} = Memory.start_link(owner: self())
    assert {:ok, store} = Memory.store(memory)

    assert {:ok, context} =
             OAuthContext.new(tenant_id: "tenant", principal_id: "principal", store: store)

    assert {:ok, registry} = InstallationCatalog.runtime_registry(catalog, context)

    limits = Limits.installed_defaults()

    assert {:error, :oauth_runtime_bound} =
             ProviderRegistry.prepare(registry, "selected", %{}, %{
               application_content_digest: String.duplicate("0", 64),
               destination: :workflow,
               owner: self(),
               limits: limits,
               installed_limits: limits
             })
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

    assert {:ok, memory} = Memory.start_link(owner: self())
    assert {:ok, store} = Memory.store(memory)

    assert {:ok, context} =
             OAuthContext.new(tenant_id: "tenant", principal_id: "principal", store: store)

    malformed_catalog = %{catalog | descriptors: []}

    assert {:error, :invalid_provider_registry} =
             InstallationCatalog.runtime_registry(malformed_catalog, context)

    assert {:ok, %{"oauth-primary" => _epoch}} =
             Store.claim_authorities(
               store,
               "tenant",
               [{"oauth-primary", "different-fingerprint"}],
               1_000
             )
  end

  test "failed OAuth owner transfer leaves the authority store unchanged" do
    assert {:ok, decoded} = HostConfig.decode(oauth_host_document("issuer.example"), "/tmp")

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
    assert :ok = InstallationCatalog.close(catalog)
    refute Process.alive?(catalog.owner.pid)

    assert {:ok, memory} = Memory.start_link(owner: self())
    assert {:ok, store} = Memory.store(memory)

    assert {:ok, context} =
             OAuthContext.new(tenant_id: "tenant", principal_id: "principal", store: store)

    assert {:error, :invalid_provider_registry} =
             InstallationCatalog.runtime_registry(catalog, context)

    assert {:ok, %{"oauth-primary" => _epoch}} =
             Store.claim_authorities(
               store,
               "tenant",
               [{"oauth-primary", "different-fingerprint"}],
               1_000
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

    captured_authority =
      [
        catalog.credential_resolver
        | Enum.flat_map(catalog.implementations, fn {_name, implementation} ->
            Map.values(implementation)
          end)
      ]
      |> Enum.filter(&is_function/1)
      |> Enum.flat_map(fn callback ->
        {:env, environment} = :erlang.fun_info(callback, :env)
        environment
      end)
      |> :erlang.term_to_binary()

    refute captured_authority =~ "/definitely/not/read"
    refute captured_authority =~ "private-selector"

    assert InstallationCatalog.names(catalog) ==
             ~w(inspection live oauth replay static trace)

    assert catalog.descriptors["static"].authorization_mode == :none
    assert catalog.descriptors["static"].credential_names == ["token"]
    assert catalog.descriptors["static"].connectivity_mode == :acquisition

    assert %Authority{} = catalog.authorities["oauth"]
    assert catalog.descriptors["oauth"].authorization_mode == :oauth

    assert catalog.descriptors["oauth"].authority_fingerprint ==
             catalog.authorities["oauth"].fingerprint

    assert catalog.descriptors["oauth"].credential_names == []

    assert catalog.descriptors["live"].connectivity_mode == :probe
    assert catalog.descriptors["live"].probe_effect == :completion
    assert catalog.descriptors["replay"].connectivity_mode == :none
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
    refute encoded =~ catalog.authorities["oauth"].fingerprint
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
          <<"ptc.effective-application.v1", 0>>,
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
                 prepared.mission_bundle,
                 prepared.entry_source,
                 activity,
                 active_catalog,
                 forged_metadata
               )
             end)

    assert {:ok, run_ref} = CommandRunRef.generate()

    assert {:error, :invalid_command_preparation} =
             CommandPreparation.new(:validate, run_ref, prepared, other_catalog, %{}, [])

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
               prepared.mission_bundle,
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
                 prepared.mission_bundle,
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
                 prepared.mission_bundle,
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
             "workflow_bundle_hash" => outcome.envelope["result"]["workflow_bundle_hash"],
             "mission_bundle_hash" => nil,
             "provider_activity" => false
           }
  end

  defp manifest do
    %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{"workflow" => [], "mission" => []}
    }
  end

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
                   local_preflight: fn _selection, _context -> :ok end
                 }
                 |> maybe_oauth_builder(authority)
                 |> maybe_active_validator(selection_validation)
             }
           }
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

  defp oauth_authority(issuer_host) do
    {:ok, decoded} = HostConfig.decode(oauth_host_document(issuer_host), "/tmp")
    decoded.install["oauth"].transport.oauth
  end

  defp oauth_host_document(issuer_host) do
    %{
      "install" => %{
        "oauth" => %{
          "source" => "mcp",
          "installation_revision" => "oauth-v1",
          "transport" => %{
            "type" => "streamable_http",
            "endpoint" => "https://mcp.example/mcp",
            "oauth" => %{
              "installation_id" => "oauth-primary",
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
end
