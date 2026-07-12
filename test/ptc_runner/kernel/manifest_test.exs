defmodule PtcRunner.Kernel.ManifestTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder

  @tag :tmp_dir
  test "one strict manifest deterministically builds and runs the shared Kernel path", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "workflow"))

    File.write!(
      Path.join(dir, "workflow/main.lisp"),
      ~S|(ns workflow.main) (defn run [input] (return (get input "value")))|
    )

    File.write!(Path.join(dir, "input.json"), Jason.encode!(%{"value" => 42}))
    File.ln_s!("main.lisp", Path.join(dir, "workflow/link.lisp"))

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "workflow.main", "path" => "workflow/link.lisp"}],
        "entry" => "workflow.main/run"
      },
      "input" => %{"path" => "input.json"},
      "events" => %{"policy" => "normal", "run_id" => "manifest-run"}
    }

    path = Path.join(dir, "ptc.json")
    File.write!(path, Jason.encode!(manifest))
    linked_path = Path.join(dir, "linked.json")
    File.ln_s!("ptc.json", linked_path)
    {:ok, registry} = ProviderRegistry.new()

    assert {:ok, first} = RunBuilder.load_and_build(linked_path, registry)
    assert {:ok, second} = RunBuilder.load_and_build(path, registry)
    assert first.entry_source == "(workflow.main/run data/input)"

    assert first.config.workflow_environment.bundle.hash ==
             second.config.workflow_environment.bundle.hash

    assert {:ok, %{value: 42}} = RunBuilder.run(path, registry)
  end

  @tag :tmp_dir
  test "manifest rejects unknown keys, duplicate JSON keys, versions, and path escape", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "source.lisp"), "(ns safe) (defn run [_] (return 1))")
    outside = dir <> "-outside.lisp"
    File.write!(outside, "(ns outside) (defn run [_] (return 1))")
    on_exit(fn -> File.rm(outside) end)

    base = fn path ->
      %{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "safe", "path" => path}],
          "entry" => "safe/run"
        },
        "input" => %{"value" => %{}}
      }
    end

    for manifest <- [
          Map.put(base.("source.lisp"), "unknown", true),
          Map.put(base.("source.lisp"), "version", 2),
          base.("../#{Path.basename(outside)}")
        ] do
      path = Path.join(dir, "invalid-#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(manifest))
      assert {:error, _reason} = Manifest.load(path)
    end

    duplicate =
      ~S|{"version":1,"version":1,"workflow":{"components":[],"entry":"safe/run"},"input":{"value":{}}}|

    duplicate_path = Path.join(dir, "duplicate.json")
    File.write!(duplicate_path, duplicate)
    assert {:error, :duplicate_json_key} = Manifest.load(duplicate_path)
  end

  @tag :tmp_dir
  test "provider registry rejects authority expansion and only calls host builders", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "main.lisp"), "(ns main) (defn run [_] (return 1))")

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "main", "path" => "main.lisp"}],
        "entry" => "main/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" => [%{"name" => "evil", "config" => %{}}]
      }
    }

    path = Path.join(dir, "provider.json")
    File.write!(path, Jason.encode!(manifest))
    {:ok, registry} = ProviderRegistry.new()
    assert {:error, :unknown_provider} = RunBuilder.load_and_build(path, registry)

    assert {:error, :invalid_provider_registry} =
             ProviderRegistry.new(%{"llm" => fn _config, _context -> :ok end})

    parent = self()

    builder = fn config, context ->
      send(parent, {:provider_built, config, context.destination})
      Capability.new(name: "fixture", callback: fn _arguments -> {:ok, true} end)
    end

    {:ok, custom_registry} = ProviderRegistry.new(%{"fixture" => builder})

    custom_manifest =
      put_in(manifest, ["providers", "workflow"], [
        %{"name" => "fixture", "config" => %{"mode" => "read"}}
      ])

    File.write!(path, Jason.encode!(custom_manifest))
    assert {:ok, _built} = RunBuilder.load_and_build(path, custom_registry)
    assert_receive {:provider_built, %{"mode" => "read"}, :workflow}

    denied_manifest =
      put_in(manifest, ["providers", "workflow"], [
        %{"name" => "file-read", "config" => %{"root" => "fixtures"}}
      ])

    File.write!(path, Jason.encode!(denied_manifest))
    assert {:error, :provider_destination_denied} = RunBuilder.load_and_build(path, registry)
  end
end
