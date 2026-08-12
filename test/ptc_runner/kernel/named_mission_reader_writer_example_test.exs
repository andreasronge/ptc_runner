defmodule PtcRunner.Kernel.NamedMissionReaderWriterExampleTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ProviderRegistry

  @host Path.expand(
          "../../../examples/named-mission-reader-writer/ptc-host.json",
          __DIR__
        )

  test "the example writer provider advertises an acquirable tool catalog" do
    assert {:ok, host} = HostConfig.load(@host)
    assert {:ok, catalog} = HostInstallation.catalog(host)
    on_exit(fn -> InstallationCatalog.close(catalog) end)

    assert {:ok, registry} = HostInstallation.runtime_registry(host, catalog)
    assert {:ok, limits} = Limits.new()

    context = %{
      application_content_digest: String.duplicate("0", 64),
      destination: :mission,
      owner: self(),
      limits: limits,
      installed_limits: limits
    }

    assert {:ok, %{capabilities: [capability], close: close}} =
             ProviderRegistry.build(
               registry,
               "writer_workspace",
               %{"allow" => ["workspace.write"]},
               context
             )

    on_exit(fn -> close.() end)
    assert capability.name == "workspace.write"
    assert capability.effect == :write
  end
end
