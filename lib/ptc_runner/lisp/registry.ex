defmodule PtcRunner.Lisp.Registry do
  @moduledoc """
  Single source of truth for PTC-Lisp function metadata.

  Loads `priv/functions.exs` at compile time via `@external_resource`.
  No runtime file I/O — recompiles automatically when the registry changes.

  ## Usage

      Registry.doc("filter")
      #=> %{name: "filter", signatures: [...], ...}

      Registry.builtins_by_category(:string)
      #=> [:format, :name, :str, ...]

      Registry.find_doc("sort")
      #=> [%{name: "sort", ...}, %{name: "sort-by", ...}]

  See also: `PtcRunner.Lisp.Env`, `PtcRunner.Lisp.Analyze`
  """

  @registry_path "priv/functions.exs"

  # Compile-time loading (no runtime file I/O)
  @external_resource @registry_path
  @registry Code.eval_file(@registry_path) |> elem(0)

  @doc """
  Returns all implemented function entries.

  ## Examples

      iex> entries = PtcRunner.Lisp.Registry.implemented()
      iex> is_list(entries) and length(entries) > 100
      true
  """
  @spec implemented() :: [map()]
  def implemented, do: @registry.implemented

  @doc """
  Returns all clojure.core audit entries.

  ## Examples

      iex> entries = PtcRunner.Lisp.Registry.clojure_core_audit()
      iex> is_list(entries) and length(entries) > 400
      true
  """
  @spec clojure_core_audit() :: [map()]
  def clojure_core_audit, do: @registry.clojure_core_audit

  @doc """
  Returns all clojure.string audit entries.

  ## Examples

      iex> entries = PtcRunner.Lisp.Registry.clojure_string_audit()
      iex> is_list(entries) and length(entries) > 15
      true
  """
  @spec clojure_string_audit() :: [map()]
  def clojure_string_audit, do: @registry.clojure_string_audit

  @doc """
  Returns all clojure.set audit entries.

  ## Examples

      iex> entries = PtcRunner.Lisp.Registry.clojure_set_audit()
      iex> is_list(entries) and length(entries) > 8
      true
  """
  @spec clojure_set_audit() :: [map()]
  def clojure_set_audit, do: @registry.clojure_set_audit

  @doc """
  Returns all java.lang.Math audit entries.

  ## Examples

      iex> entries = PtcRunner.Lisp.Registry.java_math_audit()
      iex> is_list(entries) and length(entries) > 30
      true
  """
  @spec java_math_audit() :: [map()]
  def java_math_audit, do: @registry.java_math_audit

  @doc """
  Returns all Java interop entries.

  ## Examples

      iex> entries = PtcRunner.Lisp.Registry.java_interop()
      iex> is_list(entries) and length(entries) > 5
      true
  """
  @spec java_interop() :: [map()]
  def java_interop, do: @registry.java_interop

  @doc """
  Returns env-dispatched builtin names for the given category.

  ## Examples

      iex> :join in PtcRunner.Lisp.Registry.builtins_by_category(:string)
      true

      iex> :set in PtcRunner.Lisp.Registry.builtins_by_category(:set)
      true
  """
  @spec builtins_by_category(atom()) :: [atom()]
  def builtins_by_category(category) do
    implemented()
    |> Enum.filter(&(&1.category == category and &1.dispatch == :env))
    |> Enum.map(&String.to_existing_atom(&1.name))
  end

  @doc """
  Returns a human-readable name for a category.

  ## Examples

      iex> PtcRunner.Lisp.Registry.category_name(:string)
      "String"

      iex> PtcRunner.Lisp.Registry.category_name(:core)
      "Core"
  """
  @spec category_name(atom()) :: String.t()
  def category_name(:string), do: "String"
  def category_name(:set), do: "Set"
  def category_name(:regex), do: "Regex"
  def category_name(:math), do: "Math"
  def category_name(:interop), do: "Interop"
  def category_name(:core), do: "Core"

  @doc """
  Looks up documentation for a function by exact name.

  Handles namespace-qualified names (e.g., `"LocalDate/parse"` → `"parse"`,
  `"System/currentTimeMillis"` → `"currentTimeMillis"`).

  ## Examples

      iex> entry = PtcRunner.Lisp.Registry.doc("filter")
      iex> entry.name
      "filter"

      iex> entry = PtcRunner.Lisp.Registry.doc("LocalDate/parse")
      iex> entry.name
      "parse"
  """
  @spec doc(String.t()) :: map() | nil
  def doc(name) do
    Enum.find(implemented(), &(&1.name == name)) ||
      case String.split(name, "/", parts: 2) do
        [_ns, func] -> Enum.find(implemented(), &(&1.name == func))
        _ -> nil
      end
  end

  @doc """
  Searches functions by name, description, or section pattern.

  ## Examples

      iex> results = PtcRunner.Lisp.Registry.find_doc("sort")
      iex> Enum.any?(results, & &1.name == "sort")
      true

      iex> results = PtcRunner.Lisp.Registry.find_doc("interop")
      iex> Enum.all?(results, & &1.section == "Interop")
      true
  """
  @spec find_doc(String.t()) :: [map()]
  def find_doc(pattern) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} ->
        Enum.filter(implemented(), fn entry ->
          Regex.match?(regex, entry.name) or Regex.match?(regex, entry.description) or
            Regex.match?(regex, entry.section)
        end)

      {:error, _} ->
        lower = String.downcase(pattern)

        Enum.filter(implemented(), fn entry ->
          String.contains?(String.downcase(entry.name), lower) or
            String.contains?(String.downcase(entry.description), lower) or
            String.contains?(String.downcase(entry.section), lower)
        end)
    end
  end
end
