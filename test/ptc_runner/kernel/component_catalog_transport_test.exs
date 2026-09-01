defmodule PtcRunner.Kernel.ComponentCatalogTransportTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.ComponentCatalog
  alias PtcRunner.TestSupport.CatalogTransport

  @live_evaluators 4
  @padding_bytes 262_144
  @copy_slack_bytes 65_536

  test "concurrent live evaluators share interned catalog bytes" do
    source = large_source()
    {:ok, component} = Component.new(id: "transport", source: source)
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, _intern, catalog} = ComponentCatalog.build([component], bundle)
    {:ok, entry} = ComponentCatalog.fetch(catalog, "transport")
    source_bytes = byte_size(entry.source)
    assert source_bytes > @copy_slack_bytes * 2

    CatalogTransport.assert_shared_interned_bytes!(
      @live_evaluators,
      [prelude: bundle.prelude],
      [prelude: bundle.prelude, component_catalog: catalog],
      source_bytes,
      @copy_slack_bytes
    )
  end

  defp large_source do
    padding = String.duplicate("x", @padding_bytes)
    "(ns transport)\n(def padding \"#{padding}\")\n"
  end
end
