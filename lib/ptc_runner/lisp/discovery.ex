defmodule PtcRunner.Lisp.Discovery do
  @moduledoc """
  Local REPL-style discovery for executable PTC-Lisp capabilities.

  This module is deliberately pure and registry-backed: it exposes only
  implemented PTC/Clojure builtins and curated Java interop entries. It does
  not reflect over the JVM or discover arbitrary Java members.
  """

  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Export
  alias PtcRunner.Lisp.Registry

  # Discovery source ranks. `sort_matches/1` sorts ASCENDING on `source_rank`,
  # so a LOWER rank ranks FIRST. Capability Prelude V1 (plan §8) pins exact
  # prelude exports as the HIGHEST-priority source: prelude (-1) outranks both
  # MCP (0) and local/built-in (2). The pre-existing MCP-vs-local relationship
  # is preserved unchanged (upstream tools out-rank local builtins for a
  # matching query — see `PtcRunner.Upstream.Discovery` and the
  # upstream-runtime apropos test), so V1 only inserts prelude at the top.
  @prelude_source_rank -1
  @local_source_rank 2

  # Curated Lisp-facing namespace names exposed by `(all-ns)`. Deliberately a
  # small allow-list of the namespaces user code can `dir`/`ns-publics` against,
  # NOT the raw internal bounded vocabulary: no BEAM internals, Java classes, or
  # implementation-only namespaces (plan §8). Prelude-declared namespaces are
  # merged in at call time.
  @curated_namespaces ~w(clojure.core clojure.string clojure.set clojure.walk json)

  @class_aliases %{
    "Math" => "java.lang.Math",
    "java.lang.Math" => "java.lang.Math",
    "System" => "java.lang.System",
    "java.lang.System" => "java.lang.System",
    "Boolean" => "java.lang.Boolean",
    "java.lang.Boolean" => "java.lang.Boolean",
    "Double" => "java.lang.Double",
    "java.lang.Double" => "java.lang.Double",
    "Float" => "java.lang.Float",
    "java.lang.Float" => "java.lang.Float",
    "Integer" => "java.lang.Integer",
    "java.lang.Integer" => "java.lang.Integer",
    "Long" => "java.lang.Long",
    "java.lang.Long" => "java.lang.Long",
    "String" => "java.lang.String",
    "java.lang.String" => "java.lang.String",
    "LocalDate" => "java.time.LocalDate",
    "java.time.LocalDate" => "java.time.LocalDate",
    "Instant" => "java.time.Instant",
    "java.time.Instant" => "java.time.Instant",
    "Duration" => "java.time.Duration",
    "java.time.Duration" => "java.time.Duration",
    "Date" => "java.util.Date",
    "java.util.Date" => "java.util.Date",
    "java.util.Date." => "java.util.Date"
  }

  @java_lang_classes MapSet.new([
                       "java.lang.Math",
                       "java.lang.System",
                       "java.lang.Boolean",
                       "java.lang.Double",
                       "java.lang.Float",
                       "java.lang.Integer",
                       "java.lang.Long",
                       "java.lang.String"
                     ])

  @namespace_aliases %{
    "clojure.core" => :"clojure.core",
    "core" => :"clojure.core",
    "clojure.string" => :"clojure.string",
    "str" => :"clojure.string",
    "string" => :"clojure.string",
    "clojure.set" => :"clojure.set",
    "set" => :"clojure.set",
    "clojure.walk" => :"clojure.walk",
    "walk" => :"clojure.walk",
    "regex" => :regex,
    "json" => :json
  }

  @doc """
  Returns rendered local apropos lines.
  """
  @spec apropos(term(), map()) :: {:ok, [String.t()]} | {:programmer_fault, String.t()}
  def apropos(query, opts \\ %{}) do
    with {:ok, opts} <- parse_apropos_opts(opts),
         :ok <- validate_query(query, "apropos") do
      limit = Map.get(opts, :limit, 8)

      lines =
        query
        |> apropos_matches(Map.put(opts, :limit, :all))
        |> sort_matches()
        |> Enum.take(limit)
        |> render_matches()

      {:ok, lines}
    end
  end

  @doc """
  Returns structured local apropos matches for unified MCP/local ordering.
  """
  @spec apropos_matches(String.t(), map()) :: [map()]
  def apropos_matches(query, _opts \\ %{}) when is_binary(query) do
    query_tokens = tokenize(query)

    local_entries()
    |> Enum.map(&score_local_entry(&1, query_tokens))
    |> Enum.reject(&(&1.score <= 0))
  end

  @doc """
  Lists members for a known local namespace or curated Java class.
  """
  @spec dir(term(), map()) :: {:ok, [String.t()]} | :unknown | {:programmer_fault, String.t()}
  def dir(ref, opts \\ %{}) do
    with {:ok, opts} <- parse_dir_opts(opts),
         {:ok, name} <- normalize_ref(ref, "dir") do
      limit = Map.get(opts, :limit, 50)
      offset = Map.get(opts, :offset, 0)

      cond do
        local_namespace?(name) ->
          {:ok,
           name
           |> namespace_entries()
           |> Enum.sort_by(& &1.name)
           |> Enum.drop(offset)
           |> Enum.take(limit)
           |> Enum.map(&dir_line/1)}

        local_class?(name) ->
          {:ok,
           name
           |> class_entries()
           |> Enum.sort_by(& &1.name)
           |> Enum.drop(offset)
           |> Enum.take(limit)
           |> Enum.map(&dir_line/1)}

        true ->
          :unknown
      end
    end
  end

  @doc """
  Returns human-readable docs for a known local function or Java interop ref.
  """
  @spec doc(term()) :: {:ok, String.t()} | :unknown | {:programmer_fault, String.t()}
  def doc(ref) do
    with {:ok, name} <- normalize_ref(ref, "doc") do
      case find_entry(name) do
        nil -> :unknown
        entry -> {:ok, doc_text(entry)}
      end
    end
  end

  @doc """
  Returns compact metadata for a known local function or Java interop ref.
  """
  @spec meta(term()) :: {:ok, map()} | :unknown | {:programmer_fault, String.t()}
  def meta(ref) do
    with {:ok, name} <- normalize_ref(ref, "meta") do
      case find_entry(name) do
        nil -> :unknown
        entry -> {:ok, meta_map(entry)}
      end
    end
  end

  @doc """
  Returns public vars for local Clojure/PTC namespaces only.
  """
  @spec ns_publics(term()) :: {:ok, map()} | :unknown | {:programmer_fault, String.t()}
  def ns_publics(ref) do
    with {:ok, name} <- normalize_ref(ref, "ns-publics") do
      if local_namespace?(name) do
        publics =
          name
          |> namespace_entries()
          |> Enum.sort_by(& &1.name)
          |> Map.new(fn entry -> {entry.name, public_meta(entry)} end)

        {:ok, publics}
      else
        :unknown
      end
    end
  end

  # ============================================================
  # Capability Prelude V1 discovery (plan §8)
  #
  # Prelude export records are consulted BEFORE local/MCP discovery for exact
  # refs, and merged ahead of them in `apropos`. The SAME `%Export{}` records
  # the analyzer/evaluator use back these forms — no separate registry. Private
  # helpers (`defn-`) have no export record, so they never surface here.
  # ============================================================

  @doc """
  Public exports of a prelude namespace as a `{symbol-string => meta}` map, or
  `:unknown` when `ref` is not a declared prelude namespace.
  """
  @spec prelude_ns_publics(Prelude.t() | nil, term()) ::
          {:ok, map()} | :unknown | {:programmer_fault, String.t()}
  def prelude_ns_publics(prelude, ref) do
    with {:ok, name} <- normalize_ref(ref, "ns-publics") do
      case prelude_namespace_exports(prelude, name) do
        :unknown ->
          :unknown

        exports ->
          publics =
            exports
            |> Enum.sort_by(& &1.symbol)
            |> Map.new(fn export -> {export.symbol, export_public_meta(export)} end)

          {:ok, publics}
      end
    end
  end

  @doc """
  Human-readable docs for an exact prelude export ref (e.g. `"crm/get-user"`),
  or `:unknown` when there is no such public export.
  """
  @spec prelude_doc(Prelude.t() | nil, term()) ::
          {:ok, String.t()} | :unknown | {:programmer_fault, String.t()}
  def prelude_doc(prelude, ref) do
    with {:ok, name} <- normalize_ref(ref, "doc") do
      case fetch_prelude_export(prelude, name) do
        {:ok, export} -> {:ok, export_doc_text(export)}
        :error -> :unknown
      end
    end
  end

  @doc """
  Rendered defining-form source for an exact prelude ref (e.g.
  `"crm/get-user"`), or `:unknown` when the ref is not in the prelude's
  `source_index`.

  Resolves ONLY against the attached prelude — unlike `prelude_doc`/`prelude_meta`
  there is no local/MCP fallthrough (plan D2). The index covers public exports
  plus the private helpers transitively reachable from a public export, so a
  reachable `defn-` helper is `source`-visible even though it has no `%Export{}`
  (and so stays invisible to `doc`/`meta`/`ns-publics`/`apropos`).
  """
  @spec prelude_source(Prelude.t() | nil, term()) ::
          {:ok, String.t()} | :unknown | {:programmer_fault, String.t()}
  def prelude_source(prelude, ref) do
    with {:ok, name} <- normalize_ref(ref, "source") do
      case prelude do
        %Prelude{source_index: idx} ->
          case Map.fetch(idx, name) do
            {:ok, src} -> {:ok, src}
            :error -> :unknown
          end

        _ ->
          :unknown
      end
    end
  end

  @doc """
  Compact metadata map for an exact prelude export ref, or `:unknown`.
  """
  @spec prelude_meta(Prelude.t() | nil, term()) ::
          {:ok, map()} | :unknown | {:programmer_fault, String.t()}
  def prelude_meta(prelude, ref) do
    with {:ok, name} <- normalize_ref(ref, "meta") do
      case fetch_prelude_export(prelude, name) do
        {:ok, export} -> {:ok, export_meta_map(export)}
        :error -> :unknown
      end
    end
  end

  @doc """
  `dir`-style member lines for a prelude namespace, or `:unknown` when `ref`
  is not a declared prelude namespace. Honors the same `:limit`/`:offset`
  pagination opts as the local/MCP `dir` paths.
  """
  @spec prelude_dir(Prelude.t() | nil, term(), map()) ::
          {:ok, [String.t()]} | :unknown | {:programmer_fault, String.t()}
  def prelude_dir(prelude, ref, opts \\ %{}) do
    with {:ok, opts} <- parse_dir_opts(opts),
         {:ok, name} <- normalize_ref(ref, "dir") do
      case prelude_namespace_exports(prelude, name) do
        :unknown ->
          :unknown

        exports ->
          limit = Map.get(opts, :limit, 50)
          offset = Map.get(opts, :offset, 0)

          {:ok,
           exports
           |> Enum.sort_by(& &1.symbol)
           |> Enum.drop(offset)
           |> Enum.take(limit)
           |> Enum.map(&export_dir_line/1)}
      end
    end
  end

  @doc """
  Sorted list of curated Lisp-facing namespace-name strings (plan §8), with the
  attached prelude's declared namespaces merged in. Never leaks BEAM internals,
  Java classes, or implementation-only namespaces.
  """
  @spec all_ns(Prelude.t() | nil) :: {:ok, [String.t()]}
  def all_ns(prelude) do
    prelude_namespaces =
      case prelude do
        %Prelude{} = p -> Prelude.namespaces(p)
        _ -> []
      end

    names =
      (@curated_namespaces ++ prelude_namespaces)
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, names}
  end

  @doc """
  Returns the namespace-name string for a known namespace ref (a curated
  Lisp-facing namespace or a prelude-declared namespace), or `:unknown`.
  """
  @spec ns_name(Prelude.t() | nil, term()) ::
          {:ok, String.t()} | :unknown | {:programmer_fault, String.t()}
  def ns_name(prelude, ref) do
    with {:ok, name} <- normalize_ref(ref, "ns-name") do
      {:ok, known_names} = all_ns(prelude)

      if name in known_names or local_namespace?(name) do
        {:ok, name}
      else
        :unknown
      end
    end
  end

  @doc """
  Structured prelude apropos matches (`@prelude_source_rank`) for unified
  ordering. Scored over each public export's ref/symbol/doc/namespace.
  """
  @spec prelude_apropos_matches(Prelude.t() | nil, String.t()) :: [map()]
  def prelude_apropos_matches(%Prelude{exports: exports}, query) when is_binary(query) do
    query_tokens = tokenize(query)

    exports
    |> Enum.map(&score_prelude_export(&1, query_tokens))
    |> Enum.reject(&(&1.score <= 0))
  end

  def prelude_apropos_matches(_prelude, query) when is_binary(query), do: []

  @doc """
  Shared lexical token scoring. Exact matches outrank prefixes; prefixes
  outrank substrings. No regex matching is used for search.
  """
  @spec score_tokens([String.t()], [String.t()], integer()) :: integer()
  def score_tokens(query_tokens, target_tokens, name_boost) do
    Enum.reduce(query_tokens, 0, fn query_token, acc ->
      best =
        Enum.reduce(target_tokens, 0, fn target_token, best ->
          cond do
            query_token == target_token -> max(best, 10 + name_boost)
            String.starts_with?(target_token, query_token) -> max(best, 5 + name_boost)
            String.contains?(target_token, query_token) -> max(best, 2 + name_boost)
            true -> best
          end
        end)

      acc + best
    end)
  end

  @spec tokenize(term()) :: [String.t()]
  def tokenize(text) when is_binary(text) do
    text
    |> split_camel_case()
    |> String.replace(~r/[_\-\s\.\/\(\),:]+/, " ")
    |> String.downcase()
    |> String.split()
    |> Enum.reject(&(&1 == ""))
  end

  def tokenize(_), do: []

  @doc """
  Sorts unified discovery matches.
  """
  @spec sort_matches([map()]) :: [map()]
  def sort_matches(matches) do
    Enum.sort_by(matches, fn match ->
      {
        Map.get(match, :source_rank, @local_source_rank),
        -Map.get(match, :score, 0),
        Map.get(match, :namespace) || Map.get(match, :server) || "",
        Map.get(match, :name) || Map.get(match, :ref) || ""
      }
    end)
  end

  @spec render_matches([map()]) :: [String.t()]
  def render_matches(matches), do: Enum.map(matches, &Map.fetch!(&1, :line))

  @spec parse_apropos_opts(term()) :: {:ok, map()} | {:programmer_fault, String.t()}
  def parse_apropos_opts(opts) do
    with {:ok, opts} <- normalize_opts(opts) do
      limit = Map.get(opts, :limit, 8)
      load = Map.get(opts, :load, false)

      cond do
        limit != :all and (not is_integer(limit) or limit < 1 or limit > 50) ->
          {:programmer_fault, "apropos :limit must be an integer 1..50, got #{inspect(limit)}"}

        not is_boolean(load) ->
          {:programmer_fault, "apropos :load must be a boolean, got #{inspect(load)}"}

        true ->
          {:ok, opts}
      end
    end
  end

  @spec parse_dir_opts(term()) :: {:ok, map()} | {:programmer_fault, String.t()}
  def parse_dir_opts(opts) do
    with {:ok, opts} <- normalize_opts(opts) do
      limit = Map.get(opts, :limit, 50)
      offset = Map.get(opts, :offset, 0)

      cond do
        not is_integer(limit) or limit < 1 or limit > 200 ->
          {:programmer_fault, "dir :limit must be an integer 1..200, got #{inspect(limit)}"}

        not is_integer(offset) or offset < 0 ->
          {:programmer_fault,
           "dir :offset must be a non-negative integer, got #{inspect(offset)}"}

        true ->
          {:ok, opts}
      end
    end
  end

  @spec local_ref?(term()) :: boolean()
  def local_ref?(ref) do
    case normalize_ref(ref, "discovery") do
      {:ok, name} ->
        local_namespace?(name) or local_class?(name) or not is_nil(find_entry(name))

      _ ->
        false
    end
  end

  defp validate_query(query, form) do
    if is_binary(query) and String.trim(query) != "" do
      :ok
    else
      {:programmer_fault, "#{form} requires query (non-empty string), got #{inspect(query)}"}
    end
  end

  defp normalize_opts(%{} = opts) do
    {:ok,
     Map.new(opts, fn
       {k, v} when is_atom(k) -> {k, v}
       {k, v} when is_binary(k) -> {safe_to_atom(k), v}
       {%LispKeyword{name: k}, v} -> {safe_to_atom(k), v}
       kv -> kv
     end)}
  end

  defp normalize_opts(other),
    do: {:programmer_fault, "discovery options must be a map, got #{inspect(other)}"}

  defp safe_to_atom("limit"), do: :limit
  defp safe_to_atom("offset"), do: :offset
  defp safe_to_atom("load"), do: :load
  defp safe_to_atom(other), do: other

  defp normalize_ref({:symbol_ref, name}, form) when is_binary(name),
    do: normalize_ref(name, form)

  defp normalize_ref(name, _form) when is_atom(name), do: {:ok, Atom.to_string(name)}
  defp normalize_ref(name, _form) when is_binary(name) and name != "", do: {:ok, name}

  defp normalize_ref(other, form),
    do:
      {:programmer_fault, "#{form} requires a quoted symbol or string ref, got #{inspect(other)}"}

  defp local_namespace?(name), do: Map.has_key?(@namespace_aliases, name)
  defp local_class?(name), do: Map.has_key?(@class_aliases, name)

  defp namespace_entries(name) do
    ns = Map.fetch!(@namespace_aliases, name)

    ns
    |> Registry.builtins_by_namespace()
    |> Enum.map(&to_string/1)
    |> Enum.map(&entry_for_builtin_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp class_entries(name) do
    class = Map.fetch!(@class_aliases, name)
    static_names = static_names_for_class(name)

    static_entries =
      static_names
      |> Enum.map(&find_entry("#{short_class_name(class)}/#{&1}"))
      |> Enum.reject(&is_nil/1)

    method_entries =
      Registry.java_interop()
      |> Enum.filter(&java_class_member?(&1, class))
      |> Enum.map(&interop_entry/1)

    (static_entries ++ method_entries)
    |> Enum.uniq_by(& &1.ref)
  end

  defp static_names_for_class(name) do
    name
    |> namespace_atom_for_class()
    |> Registry.builtins_by_namespace()
    |> Enum.map(&to_string/1)
  end

  defp namespace_atom_for_class("java.time.LocalDate"), do: :"java.time.LocalDate"
  defp namespace_atom_for_class("LocalDate"), do: :LocalDate
  defp namespace_atom_for_class("java.time.Instant"), do: :"java.time.Instant"
  defp namespace_atom_for_class("Instant"), do: :Instant
  defp namespace_atom_for_class("java.time.Duration"), do: :"java.time.Duration"
  defp namespace_atom_for_class("Duration"), do: :Duration
  defp namespace_atom_for_class("java.lang.Math"), do: :Math
  defp namespace_atom_for_class("Math"), do: :Math
  defp namespace_atom_for_class("java.lang.System"), do: :System
  defp namespace_atom_for_class("System"), do: :System
  defp namespace_atom_for_class("java.lang.Boolean"), do: :Boolean
  defp namespace_atom_for_class("Boolean"), do: :Boolean
  defp namespace_atom_for_class("java.lang.Double"), do: :Double
  defp namespace_atom_for_class("Double"), do: :Double
  defp namespace_atom_for_class("java.lang.Float"), do: :Float
  defp namespace_atom_for_class("Float"), do: :Float
  defp namespace_atom_for_class("java.lang.Integer"), do: :Integer
  defp namespace_atom_for_class("Integer"), do: :Integer
  defp namespace_atom_for_class("java.lang.Long"), do: :Long
  defp namespace_atom_for_class("Long"), do: :Long
  defp namespace_atom_for_class(_), do: :__unknown__

  defp find_entry(name) do
    find_interop_entry(name) ||
      case Registry.doc(name) do
        nil -> nil
        doc -> builtin_entry(doc, display_ref(name))
      end
  end

  defp entry_for_builtin_name(name) do
    case Registry.doc(name) do
      nil -> nil
      doc -> builtin_entry(doc, name)
    end
  end

  defp builtin_entry(doc, ref) do
    %{
      source_kind: "local",
      kind: "ptc-builtin",
      namespace: namespace_for_entry(doc),
      name: doc.name,
      ref: ref,
      description: doc.description || "",
      section: doc.section || "",
      signatures: Map.get(doc, :signatures, []),
      notes: Map.get(doc, :notes),
      see_also: Map.get(doc, :see_also, []),
      dispatch: Map.get(doc, :dispatch),
      category: Map.get(doc, :category)
    }
  end

  defp find_interop_entry(name) do
    Registry.java_interop()
    |> Enum.find(fn entry ->
      entry.name == name or executable_interop_ref(entry) == name
    end)
    |> case do
      nil -> nil
      entry -> interop_entry(entry)
    end
  end

  defp interop_entry(entry) do
    class = canonical_class(entry.class)

    %{
      source_kind: "local",
      kind: "java-interop",
      namespace: class,
      name: entry.name,
      ref: executable_interop_ref(entry),
      description: entry.description || "",
      section: "Java Interop",
      signatures: Map.get(entry, :signatures, []),
      notes: Map.get(entry, :notes),
      java_kind: entry.kind,
      class: class
    }
  end

  defp local_entries do
    builtin_entries =
      Registry.implemented()
      |> Enum.map(&builtin_entry(&1, &1.name))

    interop_entries =
      Registry.java_interop()
      |> Enum.map(&interop_entry/1)

    builtin_entries ++ interop_entries
  end

  defp score_local_entry(entry, query_tokens) do
    name_tokens = tokenize(entry.name) ++ tokenize(entry.ref)

    other_tokens =
      tokenize(entry.description) ++
        tokenize(entry.namespace) ++
        tokenize(entry.section) ++
        Enum.flat_map(entry.signatures, &tokenize/1) ++
        tokenize(entry.notes) ++
        Enum.flat_map(Map.get(entry, :see_also, []), &tokenize/1)

    score =
      score_tokens(query_tokens, name_tokens, 2) + score_tokens(query_tokens, other_tokens, 0)

    Map.merge(entry, %{
      source_rank: @local_source_rank,
      score: score,
      line: apropos_line(entry)
    })
  end

  defp apropos_line(entry) do
    description = compact_text(entry.description || "")
    suffix = if description == "", do: "", else: " - #{description}"
    "local: #{entry.ref}#{suffix}"
  end

  defp dir_line(entry) do
    description = compact_text(entry.description || "")
    suffix = if description == "", do: "", else: " - #{truncate_text(description, 120)}"
    "#{entry.name}#{suffix}"
  end

  defp doc_text(entry) do
    [
      entry.ref,
      maybe_line("Description", compact_text(entry.description)),
      maybe_line("Kind", entry.kind),
      maybe_line("Namespace", entry.namespace),
      signatures_text(entry.signatures),
      maybe_line("Notes", compact_text(entry.notes || ""))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp meta_map(entry) do
    %{
      kind: entry.kind,
      source: "local",
      namespace: entry.namespace,
      name: entry.name,
      ref: entry.ref,
      description: entry.description,
      signatures: entry.signatures,
      section: entry.section
    }
  end

  defp public_meta(entry) do
    %{
      name: entry.name,
      doc: entry.description,
      arglists: entry.signatures,
      section: entry.section,
      source: "local"
    }
  end

  # --- Prelude export discovery helpers (plan §8) ---

  # Public exports of a declared prelude namespace, or `:unknown` when `name`
  # is not a namespace the attached prelude declares.
  defp prelude_namespace_exports(%Prelude{} = prelude, name) do
    if name in Prelude.namespaces(prelude) do
      Enum.filter(prelude.exports, &(&1.namespace == name))
    else
      :unknown
    end
  end

  defp prelude_namespace_exports(_prelude, _name), do: :unknown

  defp fetch_prelude_export(%Prelude{} = prelude, ref), do: Prelude.fetch_export(prelude, ref)
  defp fetch_prelude_export(_prelude, _ref), do: :error

  defp export_public_meta(export) do
    %{
      name: export.symbol,
      doc: export.doc,
      arglists: [export_signature(export)],
      arity: export.arity,
      visibility: export.visibility,
      effect: export.effect,
      source: "prelude"
    }
  end

  defp export_meta_map(export) do
    %{
      kind: "prelude-export",
      source: "prelude",
      namespace: export.namespace,
      name: export.symbol,
      ref: export.ref,
      doc: export.doc,
      arity: export.arity,
      arglists: [export_signature(export)],
      visibility: export.visibility,
      effect: export.effect,
      provider_ref: export.provider_ref,
      requires: export.requires
    }
  end

  defp export_doc_text(export) do
    [
      export.ref,
      maybe_line("Description", compact_text(export.doc || "")),
      maybe_line("Kind", "prelude-export"),
      maybe_line("Namespace", export.namespace),
      maybe_line("Signature", export_signature(export)),
      maybe_line("Effect", to_string(export.effect))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp export_dir_line(export) do
    signature = export_signature(export)
    description = compact_text(export.doc || "")
    suffix = if description == "", do: "", else: " - #{truncate_text(description, 120)}"
    "#{signature}#{suffix}"
  end

  defp export_signature(export), do: Export.signature(export)

  defp score_prelude_export(export, query_tokens) do
    name_tokens = tokenize(export.symbol) ++ tokenize(export.ref)
    other_tokens = tokenize(export.doc) ++ tokenize(export.namespace)

    score =
      score_tokens(query_tokens, name_tokens, 2) + score_tokens(query_tokens, other_tokens, 0)

    description = compact_text(export.doc || "")
    suffix = if description == "", do: "", else: " - #{description}"

    %{
      source_kind: "prelude",
      source_rank: @prelude_source_rank,
      score: score,
      namespace: export.namespace,
      name: export.symbol,
      ref: export.ref,
      line: "prelude: #{export.ref}#{suffix}"
    }
  end

  defp maybe_line(_label, nil), do: nil
  defp maybe_line(_label, ""), do: nil
  defp maybe_line(label, value), do: "#{label}: #{value}"

  defp signatures_text([]), do: nil
  defp signatures_text(signatures), do: "Signatures: #{Enum.join(signatures, ", ")}"

  defp namespace_for_entry(entry) do
    cond do
      Map.get(entry, :category) == :string -> "clojure.string"
      Map.get(entry, :category) == :set -> "clojure.set"
      Map.get(entry, :category) == :walk -> "clojure.walk"
      Map.get(entry, :category) == :json -> "json"
      is_binary(Map.get(entry, :clojure_var)) -> "clojure.core"
      true -> to_string(Map.get(entry, :category, "local"))
    end
  end

  defp java_class_member?(entry, class) do
    entry.class
    |> String.split("/")
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(canonical_class(&1) == class))
  end

  defp canonical_class(class), do: Map.get(@class_aliases, class, class)
  defp short_class_name(class), do: class |> String.split(".") |> List.last()

  defp short_interop_ref(entry) do
    if String.starts_with?(entry.name, ".") do
      entry.name
    else
      short_class_name(canonical_class(entry.class)) <> "/" <> member_name(entry.name)
    end
  end

  defp executable_interop_ref(entry) do
    class = canonical_class(entry.class)

    cond do
      String.starts_with?(entry.name, ".") -> entry.name
      MapSet.member?(@java_lang_classes, class) -> short_interop_ref(entry)
      true -> class_qualified_ref(entry)
    end
  end

  defp class_qualified_ref(entry) do
    class = canonical_class(entry.class)

    if String.starts_with?(entry.name, ".") do
      "#{class}/#{entry.name}"
    else
      "#{class}/#{member_name(entry.name)}"
    end
  end

  defp member_name(name) do
    name
    |> String.split("/", parts: 2)
    |> List.last()
  end

  defp display_ref(name), do: name

  defp compact_text(text) when is_binary(text) do
    text
    |> String.split()
    |> Enum.join(" ")
  end

  defp compact_text(_), do: ""

  defp truncate_text(text, max) when byte_size(text) <= max, do: text
  defp truncate_text(text, max), do: binary_part(text, 0, max) <> "..."

  defp split_camel_case(text) do
    text
    |> String.graphemes()
    |> Enum.reduce({"", nil}, fn char, {acc, prev} ->
      separator? = prev && lower?(prev) && upper?(char)
      {acc <> if(separator?, do: " " <> char, else: char), char}
    end)
    |> elem(0)
  end

  defp lower?(char), do: String.downcase(char) == char and String.upcase(char) != char
  defp upper?(char), do: String.upcase(char) == char and String.downcase(char) != char
end
