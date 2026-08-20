defmodule PtcRunner.Lisp.SpecialBuiltin do
  @moduledoc """
  Metadata for context-dispatched builtin values.

  A `{:special, name}` binding needs evaluator context and therefore cannot be
  represented by an ordinary BEAM function. This catalog keeps value
  callability, higher-order dispatch, and `pcalls` zero-arity preflight in one
  place without owning any operation's implementation.
  """

  @metadata %{
    apply: %{callable?: false, dispatch: :direct, pcalls_thunk: :unsupported},
    println: %{callable?: true, dispatch: :println_bridge, pcalls_thunk: :zero},
    dir: %{callable?: true, dispatch: :introspection, pcalls_thunk: :zero},
    apropos: %{callable?: true, dispatch: :introspection, pcalls_thunk: {:arity, 1}},
    doc: %{callable?: true, dispatch: :introspection, pcalls_thunk: {:arity, 1}},
    export_meta: %{callable?: true, dispatch: :introspection, pcalls_thunk: {:arity, 1}},
    source: %{callable?: true, dispatch: :introspection, pcalls_thunk: {:arity, 1}},
    pmap: %{callable?: true, dispatch: :parallel, pcalls_thunk: {:minimum_arity, 2}},
    pcalls: %{callable?: true, dispatch: :parallel, pcalls_thunk: :zero}
  }

  @type dispatch :: :direct | :println_bridge | :introspection | :parallel
  @type pcalls_thunk ::
          :zero | :unsupported | {:arity, pos_integer()} | {:minimum_arity, pos_integer()}

  @spec callable?(atom()) :: boolean()
  def callable?(name) when is_atom(name) do
    case Map.fetch(@metadata, name) do
      {:ok, metadata} -> metadata.callable?
      :error -> false
    end
  end

  @spec callable_names() :: [atom()]
  def callable_names do
    for {name, %{callable?: true}} <- @metadata, do: name
  end

  @spec names(dispatch()) :: [atom()]
  def names(dispatch) do
    for {name, %{dispatch: ^dispatch}} <- @metadata, do: name
  end

  @spec pcalls_thunk(atom()) :: pcalls_thunk()
  def pcalls_thunk(name) when is_atom(name) do
    case Map.fetch(@metadata, name) do
      {:ok, metadata} -> metadata.pcalls_thunk
      :error -> :unsupported
    end
  end
end
