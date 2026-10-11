defimpl PtcRunner.Lisp.ComponentCatalog, for: PtcRunner.Kernel.ComponentCatalog do
  def ids(catalog), do: PtcRunner.Kernel.ComponentCatalog.ids(catalog)
  def fetch(catalog, id), do: PtcRunner.Kernel.ComponentCatalog.fetch(catalog, id)
end
