defmodule PtcRunner.Lisp.BuiltinNames do
  @moduledoc """
  Leaf source of env-dispatched builtin names, loaded from
  `priv/functions.exs` at compile time.

  Exists so `PtcRunner.Lisp.SourceAtoms` can derive the builtin-name
  half of its bounded vocabulary without calling
  `PtcRunner.Lisp.Env.initial/0` — which would pull `SourceAtoms` into
  the Lisp runtime cycle (issue #1051). This module aliases and calls
  **no** other `PtcRunner.Lisp.*` runtime module, so it stays a leaf.

  The names returned here equal `Env.initial() |> Map.keys()` exactly;
  a drift-guard test asserts the two stay in sync.
  """

  @registry_path "priv/functions.exs"

  # Compile-time loading (no runtime file I/O), mirroring Registry.
  @external_resource @registry_path
  @registry Code.eval_file(@registry_path) |> elem(0)

  # Names come from the closed compile-time registry, not user input,
  # so `String.to_atom/1` is safe and avoids depending on Env being
  # loaded first (same justification as `Registry.builtins_by_category/1`).
  @env_names @registry.implemented
             |> Enum.filter(&(&1.dispatch == :env))
             |> Enum.map(&String.to_atom(&1.name))

  @doc """
  Returns the env-dispatched builtin names as atoms.

  Equal to `PtcRunner.Lisp.Env.initial/0` keys, derived from the
  compile-time registry instead of building the runtime environment.
  """
  @spec env_names() :: [atom()]
  def env_names, do: @env_names
end
