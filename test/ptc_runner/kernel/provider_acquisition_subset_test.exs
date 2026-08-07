defmodule PtcRunner.Kernel.ProviderAcquisitionSubsetTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderAcquisition
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ProviderSession

  test "the whole application is the default subset" do
    # `acquire/5` is `acquire_subset/6` with `:all`, and every ordinary run and
    # check goes through it, so this is the shape the rest of the suite covers.
    %{package: package, registry: registry, session: session} = fixture()

    assert {:ok, acquired} = acquire(package, registry, session, :all)
    assert acquired_names(acquired) == ["alpha", "beta", "leaf"]
    assert_received {:acquired, "alpha"}
    assert_received {:acquired, "beta"}
    assert_received {:acquired, "leaf"}
  end

  test "a subset expands to its complete dependency closure" do
    # "beta" requires the service "leaf" provides, so naming beta alone must
    # acquire leaf too. Acquiring beta without it would report a dependency
    # unavailable that the application actually satisfies.
    %{package: package, registry: registry, session: session} = fixture()

    assert {:ok, acquired} = acquire(package, registry, session, [1])
    assert acquired_names(acquired) == ["beta", "leaf"]

    assert_received {:acquired, "beta"}
    assert_received {:acquired, "leaf"}
    refute_received {:acquired, "alpha"}
  end

  test "a subset needing nothing acquires only itself" do
    %{package: package, registry: registry, session: session} = fixture()

    assert {:ok, acquired} = acquire(package, registry, session, [0])
    assert acquired_names(acquired) == ["alpha"]
    refute_received {:acquired, "beta"}
    refute_received {:acquired, "leaf"}
  end

  test "the credential union is resolved once for the whole closure" do
    # Batching is the reason the closure is acquired together rather than one
    # occurrence at a time: resolving per provider would ask the host for the
    # same secret repeatedly.
    %{package: package, registry: registry, session: session} = fixture()

    assert {:ok, _acquired} = acquire(package, registry, session, [1])
    assert_received {:resolved, names}
    assert names == ["beta-key", "leaf-key"]
    refute_received {:resolved, _other}
  end

  test "an unsatisfiable dependency fails before anything is acquired" do
    %{package: package, registry: registry, session: session} =
      fixture(provides: %{"leaf" => []})

    assert {:error, :provider_dependency_unavailable} =
             acquire(package, registry, session, [1])

    refute_received {:acquired, _name}
    refute_received {:resolved, _names}
  end

  test "an ambiguous dependency fails before anything is acquired" do
    %{package: package, registry: registry, session: session} =
      fixture(provides: %{"alpha" => [:leaf_service]})

    assert {:error, :ambiguous_provider_dependency} =
             acquire(package, registry, session, [1])

    refute_received {:acquired, _name}
  end

  test "whole-application data policy is judged over the whole application" do
    # Narrowing this to the subset is how a subset would become a weaker
    # pipeline: "alpha" is outside the closure below, and its private class must
    # still decide the effective class the closure has to accept.
    %{package: package, registry: registry, session: session} =
      fixture(data_class: %{"alpha" => :private_inspection})

    assert {:error, :provider_data_class_denied} =
             acquire(package, registry, session, [1])

    refute_received {:acquired, _name}
  end

  test "an unknown target is refused rather than silently narrowed" do
    %{package: package, registry: registry, session: session} = fixture()

    assert {:error, :invalid_provider_acquisition} =
             acquire(package, registry, session, [7])

    refute_received {:acquired, _name}
  end

  test "a failure inside the closure leaves cleanup to the session that owns it" do
    # The barrier does not own the session, so a subset must not invent its own
    # unwind: the dependency acquired before the failure stays on the session's
    # cleanup stack and is closed when its owner closes, exactly as a run's is.
    %{package: package, registry: registry, session: session} =
      fixture(failing: "beta")

    assert {:error, _reason} = acquire(package, registry, session, [1])
    assert_received {:acquired, "leaf"}
    refute_received {:closed, "leaf"}

    assert :ok = ProviderSession.close(session)
    assert_receive {:closed, "leaf"}, 5_000
  end

  defp acquire(package, registry, session, targets) do
    ProviderAcquisition.acquire_subset(
      package,
      registry,
      session,
      :normal,
      fn _effective_class -> :ok end,
      targets
    )
  end

  defp acquired_names(acquired) do
    acquired.workflow.capabilities
    |> Enum.concat(acquired.mission.capabilities)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  # Three providers: "alpha" stands alone, "beta" requires the service "leaf"
  # provides. The manifest order is alpha, beta, leaf, so the closure is never
  # simply a prefix of the declarations.
  defp fixture(options \\ []) do
    parent = self()
    provides = Keyword.get(options, :provides, %{})
    data_class = Keyword.get(options, :data_class, %{})
    failing = Keyword.get(options, :failing)

    specifications = [
      {"alpha", [], Map.get(provides, "alpha", [])},
      {"beta", [:leaf_service], Map.get(provides, "beta", [])},
      {"leaf", [], Map.get(provides, "leaf", [:leaf_service])}
    ]

    builders =
      Map.new(specifications, fn {name, requires, exports} ->
        {name,
         ProviderRegistry.staged(
           builder(parent, name, requires, exports, Map.get(data_class, name, :normal), failing)
         )}
      end)

    {:ok, registry} =
      ProviderRegistry.new(builders,
        credential_resolver: fn names ->
          send(parent, {:resolved, Enum.sort(names)})
          {:ok, Map.new(names, &{&1, "secret"})}
        end
      )

    {:ok, limits} = Limits.new()
    {:ok, session} = ProviderSession.start_active(limits, "subset-operation")
    {:ok, session} = ProviderSession.begin_operation(session, :run)
    on_exit(fn -> ProviderSession.close(session) end)

    %{package: package(specifications), registry: registry, session: session}
  end

  defp builder(parent, name, requires, exports, data_class, failing) do
    fn _selection, _context ->
      {:ok, capability} =
        Capability.new(
          name: name,
          input_schema: %{"type" => "object", "additionalProperties" => false},
          callback: fn _arguments -> {:ok, %{}} end
        )

      {:ok,
       %{
         credential_names: ["#{name}-key"],
         requires: requires,
         provides: exports,
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
                   exports: Map.new(exports, &{&1, name})
                 }}
              end
            end}
         end
       }}
    end
  end

  defp package(specifications) do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => Enum.map(specifications, fn {name, _r, _p} -> %{"name" => name} end),
        "mission" => []
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (return {\"answer\" 42}))"
    }

    {:ok, request} =
      ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    request.package
  end
end
