if System.get_env("PTC_HOST_RUNTIME_CHILD") == "1" do
  defmodule PtcRunner.Kernel.HostRuntimeTest do
    use ExUnit.Case, async: false

    alias PtcRunner.Kernel.ApplicationPackage
    alias PtcRunner.Kernel.Capability
    alias PtcRunner.Kernel.CommandOutcome
    alias PtcRunner.Kernel.HostRuntime
    alias PtcRunner.Kernel.InstallationCatalog
    alias PtcRunner.Kernel.ProviderAdmission
    alias PtcRunner.Kernel.ProviderDescriptor
    alias PtcRunner.Kernel.SelectionRules
    alias PtcRunner.Kernel.ServingTemplate
    alias PtcRunner.TestSupport.MCPHTTPFixture

    @input_schema ~S({"type":"object","properties":{"n":{"type":"integer"}},"required":["n"],"additionalProperties":false})
    @result_schema ~S({"type":"object","properties":{"answer":{"type":"integer"}},"required":["answer"],"additionalProperties":false})

    setup_all do
      runtime =
        case HostRuntime.start_link([]) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      {:ok, runtime: runtime}
    end

    test "start_link is a registered singleton and refuses a ceiling above pool capacity" do
      assert {:error, {:already_started, pid}} = HostRuntime.start_link([])
      assert pid == Process.whereis(HostRuntime)
      assert HostRuntime.ready?(HostRuntime)
      assert is_integer(HostRuntime.admission_ceiling(HostRuntime))

      assert {:error, :admission_ceiling_exceeds_pool} =
               host_runtime_config_error(admission_ceiling: 10_000, pool_count: 1, pool_size: 1)
    end

    test "call executes a provider-free template", %{runtime: runtime} do
      documents = serving_documents()
      assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
      assert {:ok, template} = ServingTemplate.compile(package)
      assert {:ok, outcome} = HostRuntime.call(runtime, template, %{"n" => 21})
      assert outcome.exit_status == 0
      assert CommandOutcome.to_map(outcome)["result"]["value"] == %{"answer" => 42}
    end

    test "compiles a provider-backed template and serves it through HostRuntime", %{
      runtime: runtime
    } do
      {documents, catalog} = provider_documents()
      assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
      assert {:ok, template} = ServingTemplate.compile(package, catalog: catalog)
      assert {:error, :host_runtime_required} = ServingTemplate.call(template, %{"n" => 1})

      assert {:ok, outcome} = HostRuntime.call(runtime, template, %{"n" => 3})
      assert outcome.exit_status == 0
      assert CommandOutcome.to_map(outcome)["result"]["value"] == %{"answer" => 6}
    end

    test "dispatch-level admission saturates with a closed diagnostic", %{runtime: runtime} do
      ceiling = HostRuntime.admission_ceiling(runtime)
      holders = checkout_until_full(ceiling)

      try do
        {documents, catalog} = provider_documents()
        assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
        assert {:ok, template} = ServingTemplate.compile(package, catalog: catalog)

        assert {:error, %CommandOutcome{} = outcome} =
                 HostRuntime.call(runtime, template, %{"n" => 1})

        assert CommandOutcome.to_map(outcome)["error"]["code"] == "provider_admission_saturated"
      after
        Enum.each(holders, &release_holder/1)
      end
    end

    test "admission recovers after a crashed leaseholder", %{runtime: runtime} do
      ceiling = HostRuntime.admission_ceiling(runtime)
      holder = checkout_one()
      ref = Process.monitor(holder)
      extra = checkout_until_full(max(ceiling - 1, 0))

      try do
        Process.exit(holder, :kill)
        assert_receive {:DOWN, ^ref, :process, ^holder, _reason}, 1_000
        wait_until(fn -> ProviderAdmission.in_use() == length(extra) end)

        {documents, catalog} = provider_documents()
        assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
        assert {:ok, template} = ServingTemplate.compile(package, catalog: catalog)
        assert {:ok, outcome} = HostRuntime.call(runtime, template, %{"n" => 1})
        assert outcome.exit_status == 0
      after
        Enum.each(extra, &release_holder/1)
      end
    end

    test "concurrent HostRuntime calls complete against a local HTTP stub via ReqLLM.Finch", %{
      runtime: runtime
    } do
      parent = self()
      release = spawn(fn -> receive do: (:release -> :ok) end)

      server =
        MCPHTTPFixture.start(fn _request ->
          send(parent, {:held, self()})
          ref = Process.monitor(release)

          receive do
            {:DOWN, ^ref, :process, ^release, _reason} -> {200, [], "ok"}
          end
        end)

      try do
        {documents, catalog} = finch_documents(server.endpoint)
        assert {:ok, package} = ApplicationPackage.package_memory("app.json", documents)
        assert {:ok, template} = ServingTemplate.compile(package, catalog: catalog)

        tasks =
          Enum.map(1..2, fn n ->
            Task.async(fn -> HostRuntime.call(runtime, template, %{"n" => n}) end)
          end)

        assert_receive {:held, _pid}, 5_000
        assert_receive {:held, _pid}, 5_000
        send(release, :release)

        outcomes = Enum.map(tasks, &Task.await(&1, 10_000))
        assert Enum.all?(outcomes, &match?({:ok, %CommandOutcome{exit_status: 0}}, &1))
      after
        if Process.alive?(release), do: Process.exit(release, :kill)
        server.close.()
      end
    end

    defp host_runtime_config_error(opts) do
      # Validation happens before the named supervisor starts, so a second
      # geometry can be refused without racing the singleton.
      case HostRuntime.start_link(opts) do
        {:error, :admission_ceiling_exceeds_pool} = error -> error
        {:error, {:already_started, _pid}} -> {:error, :already_started}
        other -> other
      end
    end

    defp release_holder(pid) do
      ProviderAdmission.checkin(pid)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :ok
    end

    defp checkout_until_full(0), do: []

    defp checkout_until_full(count) do
      Enum.map(1..count, fn _index -> checkout_one() end)
    end

    defp checkout_one do
      pid = spawn(fn -> Process.sleep(60_000) end)
      assert :ok = ProviderAdmission.checkout(pid)
      pid
    end

    defp wait_until(fun) do
      wait_until(fun, System.monotonic_time(:millisecond) + 1_000)
    end

    defp wait_until(fun, deadline) do
      if fun.() do
        :ok
      else
        remaining = deadline - System.monotonic_time(:millisecond)
        assert remaining > 0

        receive do
        after
          min(20, remaining) -> wait_until(fun, deadline)
        end
      end
    end

    defp serving_documents(opts \\ []) do
      source =
        Keyword.get(
          opts,
          :source,
          ~S|(ns app) (defn run {:effect :read} [input] (return {"answer" (* 2 (get input "n"))}))|
        )

      providers = Keyword.get(opts, :providers, %{"workflow" => [], "mission" => []})

      manifest = %{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "workflow.clj"}],
          "entry" => "app/run"
        },
        "input" => %{"value" => %{"n" => 1}},
        "contracts" => %{
          "input_schema" => %{"path" => "input.schema.json"},
          "result_schema" => %{"path" => "result.schema.json"}
        },
        "providers" => providers
      }

      %{
        "app.json" => Jason.encode!(manifest),
        "workflow.clj" => source,
        "input.schema.json" => @input_schema,
        "result.schema.json" => @result_schema
      }
    end

    defp provider_documents do
      source =
        ~S|(ns app) (defn run {:effect :read} [input] (return (get (tool/stub {"n" (get input "n")}) :value)))|

      documents =
        serving_documents(
          source: source,
          providers: %{"workflow" => [%{"name" => "selected"}], "mission" => []}
        )

      {documents, catalog(fn %{"n" => n} -> {:ok, %{"answer" => n * 2}} end)}
    end

    defp finch_documents(endpoint) do
      source =
        ~S|(ns app) (defn run {:effect :read} [input] (return (get (tool/stub {"n" (get input "n")}) :value)))|

      documents =
        serving_documents(
          source: source,
          providers: %{"workflow" => [%{"name" => "selected"}], "mission" => []}
        )

      callback = fn %{"n" => n} ->
        request = Finch.build(:get, endpoint)

        case Finch.request(request, ReqLLM.Finch, receive_timeout: 10_000) do
          {:ok, %Finch.Response{status: 200}} -> {:ok, %{"answer" => n}}
          {:ok, %Finch.Response{status: status}} -> {:error, {:http_status, status}}
          {:error, reason} -> {:error, reason}
        end
      end

      {documents, catalog(callback)}
    end

    defp catalog(callback) do
      {:ok, rules} = SelectionRules.new(fields: %{}, cross_rules: [], named_sets: %{})

      {:ok, descriptor} =
        ProviderDescriptor.new(
          source: :custom,
          installation_revision: "hosted-v1",
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
          name: "stub",
          input_schema: %{
            "type" => "object",
            "properties" => %{"n" => %{"type" => "integer"}},
            "required" => ["n"],
            "additionalProperties" => false
          },
          callback: callback
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

      {:ok, catalog} =
        InstallationCatalog.new(%{
          "selected" => %{
            descriptor: descriptor,
            implementation: %{builder: staged},
            authority: nil
          }
        })

      catalog
    end
  end
else
  defmodule PtcRunner.Kernel.HostRuntimeTest do
    use ExUnit.Case, async: false

    test "runs HostRuntime tests in an isolated VM" do
      env =
        System.get_env()
        |> Map.put("MIX_ENV", "test")
        |> Map.put("PTC_HOST_RUNTIME_CHILD", "1")
        |> Enum.to_list()

      {output, status} =
        System.cmd(
          "elixir",
          ["-S", "mix", "test", "test/ptc_runner/kernel/host_runtime_test.exs", "--seed", "0"],
          cd: File.cwd!(),
          env: env,
          stderr_to_stdout: true
        )

      assert status == 0, output
    end
  end
end
