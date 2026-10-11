defimpl PtcRunner.Lisp.ComponentCatalog, for: Any do
  def ids(_catalog), do: []
  def fetch(_catalog, _id), do: :error
end
