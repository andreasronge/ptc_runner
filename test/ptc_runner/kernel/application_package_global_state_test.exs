defmodule PtcRunner.Kernel.ApplicationPackageGlobalStateTest do
  # async: false — overrides the :ptc_runner :default_max_heap app env for the whole VM (class D).
  # The rest of ApplicationPackage coverage is async in ApplicationPackageTest.
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder

  test "sealed Kernel runs ignore the ambient default compile heap" do
    previous = Application.get_env(:ptc_runner, :default_max_heap)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:ptc_runner, :default_max_heap),
        else: Application.put_env(:ptc_runner, :default_max_heap, previous)
    end)

    Application.put_env(:ptc_runner, :default_max_heap, 1)

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{"answer" => 1}},
      "providers" => %{"workflow" => [], "mission" => []}
    }

    documents = %{
      "app.json" => Jason.encode!(manifest),
      "workflow.clj" => "(ns app) (defn run [input] (return input))"
    }

    assert {:ok, request} =
             ApplicationPackage.request_memory("app.json", documents, result_projection: :native)

    {:ok, registry} = ProviderRegistry.new()
    assert {:ok, built} = RunBuilder.build(request, registry)

    assert {:ok, %{value: %{"answer" => 1}}} =
             PtcRunner.Kernel.run(built.entry_source, built.config)

    assert :ok = RunBuilder.close(built)
  end
end
