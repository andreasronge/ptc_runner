defmodule PtcRunner.Lisp.ParserHelpers do
  @moduledoc "Helper functions for parser reductions"

  alias PtcRunner.Lisp.AST

  # ============================================================
  # Number parsing
  # ============================================================

  def parse_integer(parts) do
    parts
    |> Enum.map_join(&to_string_part/1)
    |> String.to_integer()
  end

  def parse_float(parts) do
    str = Enum.map_join(parts, &to_string_part/1)

    # Use Float.parse/1 instead of String.to_float/1 to handle
    # scientific notation without decimal point (e.g., "1e5")
    case Float.parse(str) do
      {float, ""} -> float
      {float, _rest} -> float
      :error -> raise ArgumentError, "invalid float: #{str}"
    end
  end

  defp to_string_part(part) when is_integer(part), do: <<part::utf8>>
  defp to_string_part(part) when is_binary(part), do: part

  # ============================================================
  # Character/String building
  # ============================================================

  def build_char(s) when is_binary(s), do: {:string, s}
  def build_char([s]) when is_binary(s), do: {:string, s}

  def char_to_string(char), do: <<char::utf8>>

  def build_string(chars) do
    str = Enum.map_join(chars, &to_string_part/1)
    {:string, str}
  end

  # ============================================================
  # Keyword/Symbol building
  # ============================================================

  def build_keyword([name]), do: {:keyword, String.to_atom(name)}

  def build_var(parts) do
    name = Enum.join(parts)
    {:var, String.to_atom(name)}
  end

  def build_symbol(parts) do
    name = Enum.join(parts)
    AST.symbol(name)
  end

  # ============================================================
  # Collection building
  # ============================================================

  def build_vector({:vector, elements}), do: {:vector, elements}

  def build_set({:set, elements}), do: {:set, elements}

  def build_map({:map, elements}) do
    if rem(length(elements), 2) != 0 do
      raise ArgumentError, "Map literal requires even number of forms, got #{length(elements)}"
    end

    pairs =
      elements
      |> Enum.chunk_every(2)
      |> Enum.map(fn [k, v] -> {k, v} end)

    {:map, pairs}
  end

  def build_list({:list, elements}), do: {:list, elements}

  # ============================================================
  # Short function syntax
  # ============================================================

  def build_short_fn({:short_fn, body_asts}) do
    {:short_fn, body_asts}
  end
end
