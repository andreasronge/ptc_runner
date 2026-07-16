defmodule PtcRunner.Kernel.ProviderLifecycleTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunBuilder

  @schema %{"type" => "object", "additionalProperties" => false}

  test "registry normalizes legacy capabilities and validates resource-bearing builds" do
    {:ok, capability} = capability("fixture")

    builders = %{
      "legacy" => fn _config, _context -> {:ok, capability} end,
      "resource" => fn _config, context ->
        assert context.owner == self()
        assert context.limits.workflow_timeout_ms > 0

        {:ok,
         %{
           capabilities: [capability],
           snapshot: %{"provider" => "resource"},
           close: fn -> :ok end
         }}
      end
    }

    {:ok, registry} = ProviderRegistry.new(builders)
    context = %{directory: ".", destination: :workflow, owner: self(), limits: limits()}

    assert {:ok, %{capabilities: [^capability], snapshot: nil, close: nil}} =
             ProviderRegistry.build(registry, "legacy", %{}, context)

    assert {:ok,
            %{
              capabilities: [^capability],
              snapshot: %{"provider" => "resource"},
              close: close
            }} = ProviderRegistry.build(registry, "resource", %{}, context)

    assert is_function(close, 0)
  end

  @tag :tmp_dir
  test "assembly failure closes successful providers in reverse order", %{tmp_dir: dir} do
    parent = self()
    File.write!(Path.join(dir, "workflow.lisp"), "(ns app) (defn run [x] (tool/missing {}))")

    manifest =
      manifest(
        dir,
        [provider("owned", %{"id" => "workflow"})],
        [provider("owned", %{"id" => "mission"})]
      )

    {:ok, loaded} = Manifest.load(manifest)

    builder = fn %{"id" => id}, _context ->
      {:ok, capability} = capability("provided.#{id}")

      {:ok,
       %{
         capabilities: [capability],
         snapshot: nil,
         close: fn ->
           send(parent, {:closed, id})
           :ok
         end
       }}
    end

    {:ok, registry} = ProviderRegistry.new(%{"owned" => builder})

    assert {:error, {:missing_capability_requirement, ["missing"]}} =
             RunBuilder.build(loaded, registry)

    assert_receive {:closed, "mission"}
    assert_receive {:closed, "workflow"}
  end

  @tag :tmp_dir
  test "normal run and REPL closure release provider resources", %{tmp_dir: dir} do
    parent = self()
    File.write!(Path.join(dir, "workflow.lisp"), "(ns app) (defn run [x] (return x))")

    manifest = manifest(dir, [provider("owned", %{"id" => "run"})], [])
    {:ok, registry} = registry_with_close(parent)

    assert {:ok, _result} = RunBuilder.run(manifest, registry)
    assert_receive {:closed, "run"}

    repl_manifest = manifest(dir, [provider("owned", %{"id" => "repl"})], [])
    {:ok, built} = RunBuilder.load_and_build(repl_manifest, registry)
    {:ok, repl} = ReplSession.new(config: built.config)
    assert {:ok, _events} = ReplSession.close(repl)
    assert_receive {:closed, "repl"}

    refute Process.alive?(built.config.event_sink.pid)

    unused_manifest = manifest(dir, [provider("owned", %{"id" => "unused"})], [])
    {:ok, unused} = RunBuilder.load_and_build(unused_manifest, registry)
    assert :ok = RunBuilder.close(unused)
    assert_receive {:closed, "unused"}
    refute Process.alive?(unused.config.event_sink.pid)
  end

  defp registry_with_close(parent) do
    builder = fn %{"id" => id}, _context ->
      {:ok, capability} = capability("provided.#{id}")

      {:ok,
       %{
         capabilities: [capability],
         snapshot: %{"provider" => id},
         close: fn ->
           send(parent, {:closed, id})
           :ok
         end
       }}
    end

    ProviderRegistry.new(%{"owned" => builder})
  end

  defp capability(name) do
    Capability.new(name: name, input_schema: @schema, callback: fn _arguments -> {:ok, %{}} end)
  end

  defp limits do
    {:ok, limits} = Limits.new()
    limits
  end

  defp provider(name, config), do: %{"name" => name, "config" => config}

  defp manifest(dir, workflow_providers, mission_providers) do
    path = Path.join(dir, "#{System.unique_integer([:positive])}.json")

    body = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.lisp"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{"workflow" => workflow_providers, "mission" => mission_providers}
    }

    File.write!(path, Jason.encode!(body))
    path
  end
end
