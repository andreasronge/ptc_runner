defmodule PtcRunner.Kernel.ExecutionSessionOwnerPrivacyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.ProviderDescriptor
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.SelectionRules

  @credential "sentinel-credential-4f21"
  @host_secret "sentinel-host-configuration-9ab3"
  @authorization_url "https://sentinel.invalid/authorize?code=sentinel-notifier-77c5"

  test "owner status redacts the state that still reaches provider credentials" do
    parent = self()

    fixture =
      provider_fixture(
        acquire: fn credentials ->
          send(parent, {:blocked_in, :provider_acquire, credentials})
          receive do: (:never -> :never)
        end
      )

    started = start_blocked_execution(fixture)
    assert_receive {:blocked_in, :provider_acquire, %{"sentinel" => @credential}}, 5_000

    # The owner still holds a registry whose closures reach the credential
    # resolver, so redaction has to do real work rather than describe an
    # already-empty state.
    assert leaks?(:sys.get_state(started.owner_pid))

    status = :sys.get_status(started.owner_pid)
    refute leaks?(status)
    assert inspect(status) =~ "redacted"
  end

  test "crash-report projections redact state, message, reason, and log" do
    fixture = provider_fixture()
    owner = own_execution(fixture)
    state = :sys.get_state(ExecutionSessionOwner.pid(owner))

    assert %{state: :redacted, message: :redacted, reason: :redacted, log: []} =
             ExecutionSessionOwner.format_status(%{
               state: state,
               message:
                 {:"$gen_call", {self(), make_ref()}, {:resource, :put, :memory, @credential}},
               reason: {:badmatch, @host_secret},
               log: [{:error, @authorization_url}]
             })

    assert ExecutionSessionOwner.format_status(:terminate, [[], state]) ==
             [data: [{~c"State", :redacted}]]

    assert {:ok, _outcome} = ExecutionSessionOwner.await(owner)
  end

  test "a raising provider callback reports a stable signal, not its secret payload" do
    fixture =
      provider_fixture(
        acquire: fn credentials -> raise "provider failed with #{credentials["sentinel"]}" end
      )

    owner = own_execution(fixture)

    log =
      capture_log(fn ->
        # The raised message interpolates the resolved credential; the caller
        # must receive the closed acquisition diagnostic instead of that text.
        # A raise is the provider failing to be acquired, so it classifies as
        # `provider_unavailable` and names the occurrence that raised — the
        # bounded projection is the whole point, and nothing of the payload
        # travels with it.
        assert {:error, %CommandDiagnostic{} = reason} = ExecutionSessionOwner.await(owner)
        assert reason.phase == :provider_acquisition
        assert reason.code == :provider_unavailable
        assert reason.provider_activity
        assert reason.subject.name == "selected"
        assert reason.subject.operation == :acquisition
        assert reason.subject.occurrence == %{destination: :workflow, index: 0}
        refute leaks?(reason)
      end)

    refute log =~ @credential
  end

  test "the caller-facing owner handle carries no provider or authorization material" do
    fixture = provider_fixture()
    owner = own_execution(fixture)

    refute leaks?(owner)
    refute inspect(owner) =~ "sentinel"

    assert {:ok, _outcome} = ExecutionSessionOwner.await(owner)
  end

  defp leaks?(term) do
    encoded = :erlang.term_to_binary(term)
    inspected = inspect(term, limit: :infinity, printable_limit: :infinity)

    Enum.any?([@credential, @host_secret, @authorization_url], fn sentinel ->
      String.contains?(encoded, sentinel) or String.contains?(inspected, sentinel)
    end)
  end

  # `await/1` only answers the process the owner was started for, so tests that
  # need the outcome must own the run themselves.
  defp own_execution(fixture) do
    {:ok, owner} =
      ExecutionSessionOwner.start(
        fixture.prepared,
        fixture.authority,
        self(),
        fixture.execution,
        &notify/1
      )

    owner_pid = ExecutionSessionOwner.pid(owner)
    on_exit(fn -> stop(owner_pid) end)
    owner
  end

  defp start_blocked_execution(fixture) do
    parent = self()

    caller =
      spawn(fn ->
        {:ok, owner} =
          ExecutionSessionOwner.start(
            fixture.prepared,
            fixture.authority,
            self(),
            fixture.execution,
            &notify/1
          )

        send(parent, {:execution_owner, owner})
        ExecutionSessionOwner.await(owner)
      end)

    assert_receive {:execution_owner, owner}, 5_000
    owner_pid = ExecutionSessionOwner.pid(owner)

    on_exit(fn ->
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      stop(owner_pid)
    end)

    %{caller: caller, owner: owner, owner_pid: owner_pid}
  end

  defp stop(owner_pid) do
    if Process.alive?(owner_pid) do
      reference = Process.monitor(owner_pid)

      receive do
        {:DOWN, ^reference, :process, ^owner_pid, _reason} -> :ok
      after
        5_000 -> Process.exit(owner_pid, :kill)
      end
    end
  end

  # Captures the authorization sentinel exactly like the Mix frontend's shell
  # notifier captures a real one-time authorization URL.
  defp notify(url), do: flunk("unexpected authorization notice for #{url} #{@authorization_url}")

  defp provider_fixture(opts \\ []) do
    acquire = Keyword.get(opts, :acquire, fn _credentials -> fixture_capability() end)
    {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

    {:ok, descriptor} =
      ProviderDescriptor.new(
        source: :custom,
        installation_revision: "privacy-v1",
        credential_names: ["sentinel"],
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

    builder = fn _selection, _context ->
      {:ok,
       %{
         credential_names: ["sentinel"],
         preflight: fn -> {:ok, fn credentials -> acquire.(credentials) end} end
       }}
    end

    registration = %{
      descriptor: descriptor,
      implementation: %{builder: builder},
      authority: nil
    }

    {:ok, catalog} = InstallationCatalog.new(%{"selected" => registration})

    # Bound, not inlined: a literal lives in the module's constant pool, while a
    # captured binding travels inside the closure the owner's registry retains.
    credential = String.duplicate(@credential, 1)
    host_secret = String.duplicate(@host_secret, 1)

    {:ok, services} =
      ProviderRuntimeServices.new(
        activation: fn -> host_activation(host_secret) end,
        credential_resolver: fn ["sentinel"] -> {:ok, %{"sentinel" => credential}} end
      )

    {:ok, execution} = ProviderExecution.new(catalog, services, [])
    {:ok, authority} = PublicationAuthority.new([])

    manifest = %{
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

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (return 1))"
    }

    {:ok, request} =
      ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    on_exit(fn -> InstallationCatalog.close(catalog) end)
    %{prepared: prepared, catalog: catalog, execution: execution, authority: authority}
  end

  # Stands in for a host activation closure that captured raw host configuration.
  defp host_activation(_secret), do: {:ok, nil}

  defp fixture_capability do
    Capability.new(
      name: "fixture",
      input_schema: %{"type" => "object", "additionalProperties" => false},
      callback: fn _arguments -> {:ok, %{}} end
    )
  end
end
