defprotocol PtcRunner.Lisp.ComponentCatalog do
  @moduledoc """
  Host-supplied source catalog for Lisp component introspection.

  Implementations expose component IDs in dependency order and fetch entries
  with `id`, `dependencies`, `namespaces`, `source_hash`, and `source` fields.
  Values without an implementation behave as an absent catalog.
  """
  @fallback_to_any true

  @spec ids(t()) :: [binary()]
  def ids(catalog)

  @spec fetch(t(), binary()) :: {:ok, map()} | :error
  def fetch(catalog, id)
end
