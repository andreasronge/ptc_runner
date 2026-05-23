defmodule PtcRunner.Lisp.Registry do
  @moduledoc """
  Single source of truth for PTC-Lisp function metadata.

  Loads `priv/functions.exs` (implemented + Java interop entries),
  `priv/function_audit.exs` (Clojure/Java Math parity triage notes), and
  `priv/java_compat_audit.exs` (curated Java compatibility targets) at
  compile time via `@external_resource`. No runtime file I/O —
  recompiles automatically when any source file changes.

  The two files are split (#896) because their change cadence differs:
  `functions.exs` is touched when the language definition evolves, while
  `function_audit.exs` is touched when triaging Clojure/Java parity.
  Keeping them separate keeps each file in a more manageable size range
  and avoids recompiling dependents when only audit metadata changes.

  ## Usage

      Registry.doc("filter")
      #=> %{name: "filter", signatures: [...], ...}

      Registry.builtins_by_category(:string)
      #=> [:format, :name, :str, ...]

      Registry.find_doc("sort")
      #=> [%{name: "sort", ...}, %{name: "sort-by", ...}]

  See also: `PtcRunner.Lisp.Env`, `PtcRunner.Lisp.Analyze`
  """

  alias PtcRunner.Lisp.Env

  @registry_path "priv/functions.exs"
  @audit_path "priv/function_audit.exs"
  @java_compat_audit_path "priv/java_compat_audit.exs"

  # Compile-time loading (no runtime file I/O)
  @external_resource @registry_path
  @external_resource @audit_path
  @external_resource @java_compat_audit_path
  @registry Code.eval_file(@registry_path) |> elem(0)
  @audit Code.eval_file(@audit_path) |> elem(0)
  @java_compat_audit Code.eval_file(@java_compat_audit_path) |> elem(0)
  @doc_namespaces %{
    "clojure.core" => :"clojure.core",
    "core" => :core,
    "clojure.string" => :"clojure.string",
    "str" => :str,
    "string" => :string,
    "clojure.set" => :"clojure.set",
    "set" => :set,
    "clojure.walk" => :"clojure.walk",
    "walk" => :walk,
    "regex" => :regex,
    "Math" => :Math,
    "System" => :System,
    "Boolean" => :Boolean,
    "Double" => :Double,
    "Float" => :Float,
    "Integer" => :Integer,
    "Long" => :Long,
    "LocalDate" => :LocalDate,
    "java.time.LocalDate" => :"java.time.LocalDate",
    "Instant" => :Instant,
    "java.time.Instant" => :"java.time.Instant",
    "Duration" => :Duration,
    "java.time.Duration" => :"java.time.Duration",
    "json" => :json
  }

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
  def clojure_core_audit, do: @audit.clojure_core_audit

  @doc """
  Returns all clojure.string audit entries.

  ## Examples

      iex> entries = PtcRunner.Lisp.Registry.clojure_string_audit()
      iex> is_list(entries) and length(entries) > 15
      true
  """
  @spec clojure_string_audit() :: [map()]
  def clojure_string_audit, do: @audit.clojure_string_audit

  @doc """
  Returns all clojure.set audit entries.

  ## Examples

      iex> entries = PtcRunner.Lisp.Registry.clojure_set_audit()
      iex> is_list(entries) and length(entries) > 8
      true
  """
  @spec clojure_set_audit() :: [map()]
  def clojure_set_audit, do: @audit.clojure_set_audit

  @doc """
  Returns all clojure.walk audit entries.

  ## Examples

      iex> entries = PtcRunner.Lisp.Registry.clojure_walk_audit()
      iex> is_list(entries) and length(entries) > 5
      true
  """
  @spec clojure_walk_audit() :: [map()]
  def clojure_walk_audit, do: @audit.clojure_walk_audit

  @doc """
  Returns all java.lang.Math audit entries.

  ## Examples

      iex> entries = PtcRunner.Lisp.Registry.java_math_audit()
      iex> is_list(entries) and length(entries) > 30
      true
  """
  @spec java_math_audit() :: [map()]
  def java_math_audit, do: @audit.java_math_audit

  @doc """
  Returns the available curated Java compatibility audit keys.
  """
  @spec java_compat_audit_keys() :: [atom()]
  def java_compat_audit_keys, do: @java_compat_audit |> Map.keys() |> Enum.sort()

  @doc """
  Returns a curated Java compatibility audit by key.
  """
  @spec java_compat_audit(atom()) :: [map()]
  def java_compat_audit(key), do: Map.fetch!(@java_compat_audit, key)

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
    # Names come from the closed compile-time registry, not user input.
    # Using to_atom/1 avoids depending on Env being loaded first.
    |> Enum.map(&String.to_atom(&1.name))
  end

  @doc """
  Returns env-dispatched builtin names that are supported for the given
  compatibility namespace.

  Unlike `builtins_by_category/1`, this represents namespace membership rather
  than presentation grouping. For example, `clojure.core/str` is valid even
  though `str` is displayed in the String Functions section.
  """
  @spec builtins_by_namespace(atom()) :: [atom() | String.t()]
  def builtins_by_namespace(ns) when ns in [:"clojure.core", :core] do
    supported_core =
      clojure_core_audit()
      |> Enum.filter(&(&1.status == :supported))
      |> MapSet.new(& &1.name)

    implemented()
    |> Enum.filter(fn entry ->
      entry.dispatch == :env and
        entry.clojure_var != nil and
        MapSet.member?(supported_core, entry.clojure_var)
    end)
    |> Enum.map(&String.to_atom(&1.name))
  end

  def builtins_by_namespace(ns) when ns in [:"clojure.string", :str, :string],
    do: builtins_by_category(:string)

  def builtins_by_namespace(ns) when ns in [:"clojure.set", :set],
    do: builtins_by_category(:set)

  def builtins_by_namespace(ns) when ns in [:"clojure.walk", :walk],
    do: builtins_by_category(:walk)

  def builtins_by_namespace(:System), do: [:currentTimeMillis]

  def builtins_by_namespace(:Boolean), do: ["parseBoolean"]

  def builtins_by_namespace(:Double),
    do: ["parseDouble", :POSITIVE_INFINITY, :NEGATIVE_INFINITY, :NaN]

  def builtins_by_namespace(:Float), do: ["parseFloat"]
  def builtins_by_namespace(:Integer), do: ["parseInt"]
  def builtins_by_namespace(:Long), do: ["parseLong"]

  def builtins_by_namespace(ns) when ns in [:LocalDate, :"java.time.LocalDate"], do: [:parse]
  def builtins_by_namespace(ns) when ns in [:Instant, :"java.time.Instant"], do: [:parse]
  def builtins_by_namespace(ns) when ns in [:Duration, :"java.time.Duration"], do: [:between]

  def builtins_by_namespace(ns) do
    ns
    |> Env.namespace_category()
    |> case do
      nil -> []
      :interop -> []
      category -> builtins_by_category(category)
    end
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
  def category_name(:walk), do: "Walk"
  def category_name(:regex), do: "Regex"
  def category_name(:math), do: "Math"
  def category_name(:interop), do: "Interop"
  def category_name(:core), do: "Core"
  def category_name(:json), do: "JSON"
  def category_name(:mcp), do: "MCP"

  @doc """
  Looks up documentation for a function by exact name.

  Handles namespace-qualified names (e.g., `"LocalDate/parse"` → `"parse"`,
  `"System/currentTimeMillis"` → `"currentTimeMillis"`,
  `"java.time.Duration/between"` → `"Duration/between"`).

  ## Examples

      iex> entry = PtcRunner.Lisp.Registry.doc("filter")
      iex> entry.name
      "filter"

      iex> entry = PtcRunner.Lisp.Registry.doc("LocalDate/parse")
      iex> entry.name
      "parse"

      iex> entry = PtcRunner.Lisp.Registry.doc("java.time.Duration/between")
      iex> entry.name
      "Duration/between"
  """
  @spec doc(String.t()) :: map() | nil
  def doc(name) do
    Enum.find(implemented(), &(&1.name == name)) ||
      case String.split(name, "/", parts: 2) do
        [ns, func] -> doc_for_namespaced(ns, func)
        _ -> nil
      end
  end

  defp doc_for_namespaced(ns, func) do
    with {:ok, ns_atom} <- doc_namespace(ns),
         true <- namespace_member?(ns_atom, func) do
      ns
      |> canonical_doc_names(func)
      |> Enum.find_value(fn canonical -> Enum.find(implemented(), &(&1.name == canonical)) end)
    else
      _ -> nil
    end
  end

  defp doc_namespace(ns) do
    case Map.fetch(@doc_namespaces, ns) do
      {:ok, ns_atom} -> {:ok, ns_atom}
      :error -> :error
    end
  end

  defp namespace_member?(ns, func) do
    ns
    |> builtins_by_namespace()
    |> Enum.any?(&(to_string(&1) == func))
  end

  defp canonical_doc_names("Boolean", "parseBoolean"), do: ["parse-boolean"]
  defp canonical_doc_names("Double", "parseDouble"), do: ["parse-double"]
  defp canonical_doc_names("Float", "parseFloat"), do: ["parse-double"]
  defp canonical_doc_names("Integer", "parseInt"), do: ["parse-long"]
  defp canonical_doc_names("Long", "parseLong"), do: ["parse-long"]

  defp canonical_doc_names(ns, func), do: [short_qualified_name(ns, func), func]

  defp short_qualified_name(ns, func) do
    ns
    |> String.split(".")
    |> List.last()
    |> then(&"#{&1}/#{func}")
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
