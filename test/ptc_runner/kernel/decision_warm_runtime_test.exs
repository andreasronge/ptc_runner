defmodule PtcRunner.Kernel.DecisionWarmRuntimeTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias PtcRunner.TestSupport.DecisionHTTPFixture

  alias PtcRunner.Kernel.{
    HostConfig,
    HostInstallation,
    InstallationCatalog,
    Limits,
    ProviderRuntime,
    RunAdmission,
    ServingOutcome,
    ServingTemplate,
    WarmProviderRuntime
  }

  @example Path.expand("../../../examples/decision-refund-triage", __DIR__)

  for backend <- [:replay, :http] do
    @tag :tmp_dir
    test "warm decision #{backend} passes shared provider admission", %{tmp_dir: dir} do
      File.cp_r!(@example, Path.join(dir, "example"))
      directory = Path.join(dir, "example")
      host_path = Path.join(directory, "ptc-host.json")
      config = host_path |> File.read!() |> Jason.decode!()

      config =
        if unquote(backend) == :http do
          response =
            Path.join(directory, "replay.jsonl")
            |> File.read!()
            |> String.trim()
            |> Jason.decode!()
            |> Map.fetch!("response")

          fixture = DecisionHTTPFixture.start(response, self())
          on_exit(fn -> DecisionHTTPFixture.stop(fixture) end)

          put_in(config, ["install", "frozen-decisions"], %{
            "source" => "decision",
            "backend" => "http",
            "endpoint" => fixture.endpoint,
            "allow_insecure_loopback" => true,
            "model" => "declared-local",
            "installation_revision" => "http-v1",
            "usage_guarantees" => %{"tokens" => true, "cost_currency" => nil},
            "max_cost_per_call" => %{"currency" => "USD", "amount" => "0"},
            "max_total_tokens_per_call" => 8000
          })
        else
          config
        end

      config =
        Map.put(config, "credentials", %{
          "bearer" => %{"literal" => String.duplicate("fixture-token", 4)}
        })

      File.write!(host_path, Jason.encode!(config))
      {:ok, host} = HostConfig.load(host_path)
      {:ok, catalog} = HostInstallation.catalog(host)
      on_exit(fn -> InstallationCatalog.close(catalog) end)
      {:ok, services} = HostInstallation.runtime_services(host)

      manifest_path = Path.join(directory, "ptc.json")
      manifest = manifest_path |> File.read!() |> Jason.decode!()
      input = manifest["input"]["value"]
      schema = %{"type" => "object", "additionalProperties" => true}
      File.write!(Path.join(directory, "schema.json"), Jason.encode!(schema))

      manifest =
        Map.put(manifest, "contracts", %{
          "input_schema" => %{"path" => "schema.json"},
          "result_schema" => %{"path" => "schema.json"}
        })

      File.write!(manifest_path, Jason.encode!(manifest))
      source_path = Path.join(directory, "workflow.clj")

      File.write!(
        source_path,
        source_path
        |> File.read!()
        |> String.replace("(defn run [request]", "(defn run {:effect :write} [request]")
      )

      {:ok, template} =
        ServingTemplate.from_directory(
          Path.join(directory, "ptc.json"),
          Limits.installed_defaults(),
          providers: catalog
        )

      discovery =
        capture_io(fn ->
          {:ok, runtime} =
            ProviderRuntime.start_link(template: template, services: services, pins: :discover)

          GenServer.stop(runtime)
        end)
        |> Jason.decode!()

      pins = %{
        installation_config_pins: discovery["installation_config_pins"],
        provider_snapshot_pins: discovery["provider_snapshot_pins"]
      }

      admission = start_supervised!({RunAdmission, max_concurrent_runs: 2})

      {:ok, warm} =
        WarmProviderRuntime.start_link(
          tools: %{"decisions" => %{template: template, pins: pins}},
          services: services,
          bearer_binding: "bearer",
          run_admission: admission,
          max_active_provider_calls: 1,
          max_waiting_provider_calls: 1
        )

      on_exit(fn -> if Process.alive?(warm), do: GenServer.stop(warm) end)
      {:ok, bound} = WarmProviderRuntime.template(warm, "decisions")

      for _ <- 1..2 do
        result = ServingTemplate.call(bound, input, admission)
        assert ServingOutcome.code(result) == :success, inspect(result)
      end

      for item <-
            Task.async_stream(1..2, fn _ -> ServingTemplate.call(bound, input, admission) end,
              max_concurrency: 2
            ) do
        assert {:ok, result} = item
        assert ServingOutcome.code(result) == :success, inspect(result)
      end

      assert :ok = WarmProviderRuntime.drain(warm, System.monotonic_time(:millisecond) + 2000)
      GenServer.stop(warm)
    end
  end
end
