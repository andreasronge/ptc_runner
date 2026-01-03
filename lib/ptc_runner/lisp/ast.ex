defmodule PtcRunner.Lisp.AST do
  @moduledoc "AST node types for PTC-Lisp"

  # Literals
  @type t ::
          nil
          | boolean()
          | number()
          | {:string, String.t()}
          | {:keyword, atom()}
          # Collections
          | {:vector, [t()]}
          | {:map, [{t(), t()}]}
          | {:set, [t()]}
          # Symbols
          | {:symbol, atom()}
          | {:ns_symbol, :ctx | :memory, atom()}
          # Calls
          | {:list, [t()]}

  @doc "Create a keyword node"
  def keyword(name) when is_binary(name), do: {:keyword, String.to_atom(name)}

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
          ["ctx", key] -> {:ns_symbol, :ctx, String.to_atom(key)}
          ["memory", key] -> {:ns_symbol, :memory, String.to_atom(key)}
          [name] -> {:symbol, String.to_atom(name)}
          [_ns, _key] -> {:symbol, String.to_atom(name)}
        end
    end
  end

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
