defmodule PtcRunner.Lisp.BuiltinNames do
  @moduledoc """
  Leaf source of env-dispatched builtin names and binding kinds, loaded from
  `priv/functions.exs` and a code-owned Phase-0 Java binding catalog at compile
  time. It also loads the separately owned Java overload attestation baseline
  used to validate the surface manifest.

  Exists so `PtcRunner.Lisp.SourceAtoms` can derive the builtin-name
  half of its bounded vocabulary without calling
  `PtcRunner.Lisp.Env.initial/0` — which would pull `SourceAtoms` into
  the Lisp runtime cycle (issue #1051). It depends only on the Java manifest
  validator, not on another Lisp runtime module, so it stays outside that
  cycle.

  The catalog returned here equals the names and binding kinds in
  `Env.initial/0`; drift-guard tests assert the two stay in sync.
  """

  alias PtcRunner.Lisp.Java.Surface.Validator

  @registry_path "priv/functions.exs"
  @java_surface_path "priv/java_interop.exs"
  @java_phase0_attestations_path "priv/java_interop_phase0_attestations.exs"

  # Compile-time loading (no runtime file I/O), mirroring Registry.
  @external_resource @registry_path
  @external_resource @java_surface_path
  @external_resource @java_phase0_attestations_path
  @registry Code.eval_file(@registry_path) |> elem(0)
  # Ordinary builtin names come from the existing closed registry.
  @ordinary_env_entries @registry.implemented
                        |> Enum.reject(&(&1.category == :interop))
                        |> Enum.filter(&(&1.dispatch == :env))

  @ordinary_env_binding_kinds Map.new(
                                @ordinary_env_entries,
                                &{String.to_atom(&1.name), &1.binding}
                              )

  # Retained until the final migration-cleanup slice removes the legacy route
  # schema itself. Every Java overload now uses closed dispatch.
  @legacy_java_binding_kinds %{}

  @env_binding_kinds Map.merge(@ordinary_env_binding_kinds, @legacy_java_binding_kinds)
  @env_names Map.keys(@env_binding_kinds)

  # Validate before projecting any raw manifest collection. This keeps malformed
  # top-level data on the validator's structured error path.
  @java_surface Code.eval_file(@java_surface_path) |> elem(0)
  @java_phase0_attestations Code.eval_file(@java_phase0_attestations_path) |> elem(0)
  :ok =
    Validator.validate!(@java_surface, @env_binding_kinds, @java_phase0_attestations)

  @java_namespace_atoms ((@java_surface.namespaces |> Enum.map(& &1.namespace)) ++
                           (@java_surface.classes
                            |> Enum.flat_map(&[&1.name | &1.spellings])
                            |> Enum.reject(&String.ends_with?(&1, "."))
                            |> Enum.map(&String.to_atom/1)))
                        |> Enum.uniq()
  @java_member_atoms ((@java_surface.namespaces
                       |> Enum.flat_map(& &1.members)
                       |> Enum.map(& &1.source_name)
                       |> Enum.filter(&is_atom/1)) ++
                        (@java_surface.references
                         |> Enum.filter(&(&1.kind == :instance))
                         |> Enum.flat_map(& &1.spellings)
                         |> Enum.map(&String.to_atom/1)))
                     |> Enum.uniq()
  @java_constructor_atoms @java_surface.references
                          |> Enum.filter(&(&1.kind == :constructor))
                          |> Enum.flat_map(& &1.spellings)
                          |> Enum.map(&String.to_atom/1)
                          |> Enum.uniq()

  @doc """
  Returns the env-dispatched builtin names as atoms.

  Equal to `PtcRunner.Lisp.Env.initial/0` keys, derived from the
  compile-time registry instead of building the runtime environment.
  """
  @spec env_names() :: [atom()]
  def env_names, do: @env_names

  @doc false
  @spec env_binding_kinds() :: %{atom() => atom()}
  def env_binding_kinds, do: @env_binding_kinds

  @doc false
  @spec legacy_java_binding_kinds() :: %{atom() => atom()}
  def legacy_java_binding_kinds, do: @legacy_java_binding_kinds

  @doc false
  @spec java_phase0_attestations() :: map()
  def java_phase0_attestations, do: @java_phase0_attestations

  @doc "Returns Java namespace atoms from the bounded surface manifest."
  @spec java_namespace_atoms() :: [atom()]
  def java_namespace_atoms, do: @java_namespace_atoms

  @doc "Returns atom-named Java namespace members from the bounded surface manifest."
  @spec java_member_atoms() :: [atom()]
  def java_member_atoms, do: @java_member_atoms

  @doc "Returns Java constructor source atoms from the bounded surface manifest."
  @spec java_constructor_atoms() :: [atom()]
  def java_constructor_atoms, do: @java_constructor_atoms
end
