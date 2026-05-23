defmodule PtcRunner.Lisp.AST do
  @moduledoc "AST node types for PTC-Lisp"

  alias PtcRunner.Lisp.SourceAtoms

  @type name :: atom() | String.t()

  # Literals
  @type t ::
          nil
          | boolean()
          | number()
          | {:string, String.t()}
          | {:keyword, name()}
          # Collections
          | {:vector, [t()]}
          | {:map, [{t(), t()}]}
          | {:set, [t()]}
          # Symbols
          | {:symbol, name()}
          | {:ns_symbol, name(), name()}
          | {:quoted_symbol, String.t()}
          # Calls
          | {:list, [t()]}

  @doc "Create a keyword node"
  def keyword(name) when is_binary(name), do: {:keyword, SourceAtoms.intern(name)}

  @doc "Create a symbol node"
  def symbol(name) when is_binary(name) do
    case name do
      # Turn history variables: *1, *2, *3
      "*1" ->
        {:turn_history, 1}

      "*2" ->
        {:turn_history, 2}

      "*3" ->
        {:turn_history, 3}

      _ ->
        case String.split(name, "/", parts: 2) do
          [name] ->
            {:symbol, SourceAtoms.intern(name)}

          ["", _] ->
            # Handles "/" operator (division) - empty namespace means not a namespaced symbol
            {:symbol, SourceAtoms.intern(name)}

          [ns, key] when ns != "" and key != "" ->
            {:ns_symbol, SourceAtoms.intern(ns), SourceAtoms.intern(key)}

          _ ->
            # Fallback for edge cases
            {:symbol, SourceAtoms.intern(name)}
        end
    end
  end

  @doc "Create a quoted symbolic reference node without namespace splitting"
  def quoted_symbol(name) when is_binary(name), do: {:quoted_symbol, name}

  @doc "Create a vector node"
  def vector(elements), do: {:vector, elements}

  @doc "Create a map node from flat list [k1, v1, k2, v2, ...]"
  def map_node(pairs) do
    chunked = Enum.chunk_every(pairs, 2)
    {:map, Enum.map(chunked, fn [k, v] -> {k, v} end)}
  end

  @doc "Create a list (call) node"
  def list(elements), do: {:list, elements}
end
