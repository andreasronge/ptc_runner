defmodule PtcRunner.Lisp.ProtectedNamespaces do
  @moduledoc """
  Single consult point for namespace protection for deployment preludes.

  Reserved namespaces are host-owned and may never be declared by a
  deployment prelude, redefined by user code, or shadowed. The fixed host
  namespaces are `tool`, `data`, and `ptc.core`; the bounded Java surface additionally owns
  every admitted Java class spelling so prelude exports cannot be silently
  replaced by Java dispatch. The future "catalog" namespace name is deliberately
  deferred.

  Namespace names are string-backed at the host boundary, so this
  module operates on binaries.

  `protected/1` unions the reserved set with a compiled prelude's declared
  namespaces — the full set of namespace names that user code must not write
  into. This is the seam later phases (analyzer protected-write rejection)
  consult.
  """

  alias PtcRunner.Lisp.Java.Surface, as: JavaSurface
  alias PtcRunner.Lisp.Prelude

  # Fixed reserved host namespace names. Combined with the manifest's
  # Java class spellings and turned into a MapSet at runtime so public functions return a `MapSet.t()`
  # (an opaque type), not a compile-time literal with a concrete internal
  # shape. String-backed; NOT added to SourceAtoms @bounded_namespaces —
  # that would leak atoms and broaden the global vocabulary.
  #
  @reserved_names ~w(tool data ptc.core)

  @doc "The reserved (host-owned) namespace name set."
  @spec reserved() :: MapSet.t()
  def reserved do
    # Fold into an empty MapSet (rather than `MapSet.new(literal_list)`) so
    # dialyzer infers the opaque `MapSet.t()` instead of a concrete literal
    # subtype that would trip `contract_with_opaque`.
    @reserved_names
    |> Kernel.++(JavaSurface.class_spellings())
    |> Enum.into(MapSet.new())
  end

  @doc """
  Whether `name` is a reserved host namespace.

  Accepts a binary or an atom; atoms are stringified at the boundary.
  """
  @spec reserved?(String.t() | atom()) :: boolean()
  def reserved?(name) when is_binary(name), do: MapSet.member?(reserved(), name)
  def reserved?(name) when is_atom(name), do: reserved?(Atom.to_string(name))

  @doc """
  The full protected namespace set: reserved namespaces unioned with the
  namespaces a compiled prelude declares.

  Passing `nil` (no prelude attached) returns just the reserved set.
  """
  @spec protected(Prelude.t() | nil) :: MapSet.t()
  def protected(nil), do: reserved()

  def protected(%Prelude{} = prelude) do
    prelude
    |> Prelude.namespaces()
    |> MapSet.new()
    |> MapSet.union(reserved())
  end
end
