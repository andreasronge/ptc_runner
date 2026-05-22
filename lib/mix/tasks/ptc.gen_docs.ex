defmodule Mix.Tasks.Ptc.GenDocs do
  @shortdoc "Generate function reference and audit docs from registry"
  @moduledoc """
  Generates documentation from `priv/functions.exs` (implemented + interop),
  `priv/function_audit.exs` (Clojure/Java Math parity triage notes), and
  `priv/java_compat_audit.exs` (curated Java compatibility targets):

  1. `docs/function-reference.md` — all implemented functions grouped by section
  2. `docs/conformance/index.md` — namespace coverage dashboard
  3. `docs/conformance/*-audit.md` — Clojure and Java compatibility audits

  ## Usage

      mix ptc.gen_docs
  """
  use Mix.Task

  alias PtcRunner.Lisp.Registry

  @function_ref_path "docs/function-reference.md"
  @audit_index_path "docs/conformance/index.md"

  @audits [
    %{
      path: "docs/conformance/clojure-core-audit.md",
      namespace: "`clojure.core/`, `core/`",
      scope: "Clojure standard",
      target: "Clojure standard vars",
      title: "Clojure Core Audit for PTC-Lisp",
      description: "Comparison of `clojure.core` vars against PTC-Lisp builtins.",
      fetch: &Registry.clojure_core_audit/0
    },
    %{
      path: "docs/conformance/clojure-string-audit.md",
      namespace: "`clojure.string/`, `str/`, `string/`",
      scope: "Clojure standard",
      target: "Clojure standard vars",
      title: "Clojure String Audit for PTC-Lisp",
      description: "Comparison of `clojure.string` vars against PTC-Lisp builtins.",
      fetch: &Registry.clojure_string_audit/0
    },
    %{
      path: "docs/conformance/clojure-set-audit.md",
      namespace: "`clojure.set/`, `set/`",
      scope: "Clojure standard",
      target: "Clojure standard vars",
      title: "Clojure Set Audit for PTC-Lisp",
      description: "Comparison of `clojure.set` vars against PTC-Lisp builtins.",
      fetch: &Registry.clojure_set_audit/0
    },
    %{
      path: "docs/conformance/clojure-walk-audit.md",
      namespace: "`clojure.walk/`, `walk/`",
      scope: "Clojure standard",
      target: "Clojure standard vars",
      title: "Clojure Walk Audit for PTC-Lisp",
      description: "Comparison of `clojure.walk` vars against PTC-Lisp builtins.",
      fetch: &Registry.clojure_walk_audit/0
    },
    %{
      path: "docs/conformance/java-math-audit.md",
      namespace: "`Math/`, `java.lang.Math`",
      scope: "Java standard",
      target: "curated Java standard methods",
      title: "Java Math Audit for PTC-Lisp",
      description: "Comparison of `java.lang.Math` methods against PTC-Lisp builtins.",
      fetch: &Registry.java_math_audit/0
    }
  ]

  @java_compat_audits [
    %{
      key: :java_lang_boolean_audit,
      path: "docs/conformance/java-lang-boolean-audit.md",
      namespace: "`Boolean/`, `java.lang.Boolean`",
      scope: "Java standard",
      target: "curated Java standard methods/constants",
      title: "Java Boolean Audit for PTC-Lisp",
      description: "Curated LLM-compatibility target for `java.lang.Boolean`."
    },
    %{
      key: :java_lang_double_audit,
      path: "docs/conformance/java-lang-double-audit.md",
      namespace: "`Double/`, `java.lang.Double`",
      scope: "Java standard",
      target: "curated Java standard methods/constants",
      title: "Java Double Audit for PTC-Lisp",
      description: "Curated LLM-compatibility target for `java.lang.Double`."
    },
    %{
      key: :java_lang_float_audit,
      path: "docs/conformance/java-lang-float-audit.md",
      namespace: "`Float/`, `java.lang.Float`",
      scope: "Java standard",
      target: "curated Java standard methods",
      title: "Java Float Audit for PTC-Lisp",
      description: "Curated LLM-compatibility target for `java.lang.Float`."
    },
    %{
      key: :java_lang_integer_audit,
      path: "docs/conformance/java-lang-integer-audit.md",
      namespace: "`Integer/`, `java.lang.Integer`",
      scope: "Java standard",
      target: "curated Java standard methods/constants",
      title: "Java Integer Audit for PTC-Lisp",
      description: "Curated LLM-compatibility target for `java.lang.Integer`."
    },
    %{
      key: :java_lang_long_audit,
      path: "docs/conformance/java-lang-long-audit.md",
      namespace: "`Long/`, `java.lang.Long`",
      scope: "Java standard",
      target: "curated Java standard methods/constants",
      title: "Java Long Audit for PTC-Lisp",
      description: "Curated LLM-compatibility target for `java.lang.Long`."
    },
    %{
      key: :java_lang_string_audit,
      path: "docs/conformance/java-lang-string-audit.md",
      namespace: "`java.lang.String` dot methods",
      scope: "Java standard",
      target: "curated Java standard methods",
      title: "Java String Audit for PTC-Lisp",
      description: "Curated LLM-compatibility target for `java.lang.String` methods."
    },
    %{
      key: :java_lang_system_audit,
      path: "docs/conformance/java-lang-system-audit.md",
      namespace: "`System/`, `java.lang.System`",
      scope: "Java standard",
      target: "curated Java standard methods",
      title: "Java System Audit for PTC-Lisp",
      description: "Curated LLM-compatibility target for `java.lang.System`."
    },
    %{
      key: :java_time_local_date_audit,
      path: "docs/conformance/java-time-local-date-audit.md",
      namespace: "`LocalDate/`, `java.time.LocalDate/`",
      scope: "Java standard",
      target: "curated Java standard methods",
      title: "Java LocalDate Audit for PTC-Lisp",
      description: "Curated LLM-compatibility target for `java.time.LocalDate`."
    },
    %{
      key: :java_time_instant_audit,
      path: "docs/conformance/java-time-instant-audit.md",
      namespace: "`Instant/`, `java.time.Instant/`",
      scope: "Java standard",
      target: "curated Java standard methods",
      title: "Java Instant Audit for PTC-Lisp",
      description: "Curated LLM-compatibility target for `java.time.Instant`."
    },
    %{
      key: :java_time_duration_audit,
      path: "docs/conformance/java-time-duration-audit.md",
      namespace: "`Duration/`, `java.time.Duration`",
      scope: "Java standard candidate",
      target: "curated Java standard methods",
      title: "Java Duration Audit for PTC-Lisp",
      description: "Curated LLM-compatibility target for `java.time.Duration`."
    },
    %{
      key: :java_time_period_audit,
      path: "docs/conformance/java-time-period-audit.md",
      namespace: "`Period/`, `java.time.Period`",
      scope: "Java standard candidate",
      target: "curated Java standard methods",
      title: "Java Period Audit for PTC-Lisp",
      description: "Curated LLM-compatibility target for `java.time.Period`."
    },
    %{
      key: :java_util_date_audit,
      path: "docs/conformance/java-util-date-audit.md",
      namespace: "`java.util.Date.`",
      scope: "Java standard",
      target: "curated Java standard methods/constructors",
      title: "Java Date Audit for PTC-Lisp",
      description: "Curated LLM-compatibility target for `java.util.Date`."
    }
  ]

  @non_audited_namespaces [
    %{
      namespace: "`regex/`",
      scope: "Clojure standard",
      target: "audited through `clojure.core` regex vars",
      audit: "clojure-core-audit.md"
    },
    %{namespace: "`data/`", scope: "PTC extension", target: "context access", audit: nil},
    %{
      namespace: "`tool/`",
      scope: "PTC extension / capability",
      target: "registered tool calls",
      audit: nil
    },
    %{
      namespace: "`catalog/`",
      scope: "PTC extension / MCP aggregator profile",
      target: "upstream catalog discovery",
      audit: nil
    },
    %{
      namespace: "`budget/`",
      scope: "PTC extension / SubAgent budget profile",
      target: "budget introspection",
      audit: nil
    },
    %{namespace: "`json/`", scope: "PTC extension", target: "PTC JSON helpers", audit: nil},
    %{
      namespace: "`mcp/`",
      scope: "PTC extension / MCP server profile",
      target: "profile-gated helper namespace; unavailable in base `Lisp.run/2`",
      audit: nil
    }
  ]

  @interop_path "docs/java-interop.md"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    generate_function_reference()
    Enum.each(all_audits(), &generate_audit/1)
    generate_audit_index()
    generate_java_interop()
  end

  defp all_audits do
    @audits ++
      Enum.map(@java_compat_audits, fn spec ->
        Map.put(spec, :fetch, fn -> Registry.java_compat_audit(spec.key) end)
      end)
  end

  defp generate_function_reference do
    entries = Registry.implemented()

    sections =
      entries
      |> Enum.group_by(& &1.section)
      |> Enum.sort_by(fn {section, _} -> section_order(section) end)

    content = """
    <!-- Auto-generated — do not edit by hand -->
    # PTC-Lisp Function Reference

    > **Warning:** This file is auto-generated by `mix ptc.gen_docs` from `priv/functions.exs`.
    > Manual edits will be overwritten. Edit `priv/functions.exs` instead.

    #{length(entries)} functions and special forms.

    See also: [PTC-Lisp Specification](ptc-lisp-specification.md) | [Clojure Conformance Gaps](clojure-conformance-gaps.md) | [Namespace Coverage](conformance/index.md)

    ## Table of Contents

    #{toc(sections)}

    #{Enum.map_join(sections, "\n\n", &render_section/1)}
    """

    File.write!(@function_ref_path, content)
    Mix.shell().info("Generated #{@function_ref_path} (#{length(entries)} entries)")
  end

  defp toc(sections) do
    Enum.map_join(sections, "\n", fn {section, entries} ->
      anchor =
        section |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

      "- [#{section}](##{anchor}) (#{length(entries)})"
    end)
  end

  defp section_order("Definitions & Bindings"), do: 0
  defp section_order("Conditionals"), do: 1
  defp section_order("Threading Macros"), do: 2
  defp section_order("Control Flow"), do: 3
  defp section_order("Iteration"), do: 4
  defp section_order("Core"), do: 5
  defp section_order("Predicate Builders"), do: 6
  defp section_order("Functional Tools"), do: 7
  defp section_order("Agent Control"), do: 8
  defp section_order("String Functions"), do: 9
  defp section_order("Set Operations"), do: 10
  defp section_order("Regex Functions"), do: 11
  defp section_order("Math Functions"), do: 12
  defp section_order("Interop"), do: 13
  defp section_order("JSON"), do: 14
  defp section_order("MCP"), do: 15
  defp section_order(_), do: 99

  defp render_section({section, entries}) do
    rows =
      entries
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n", fn entry ->
        sigs = Enum.join(entry.signatures, ", ")
        ext = if entry.ptc_extension?, do: " *", else: ""
        "| `#{entry.name}`#{ext} | `#{sigs}` | #{entry.description} |"
      end)

    examples =
      entries
      |> Enum.flat_map(fn entry ->
        Enum.map(entry.examples, fn {code, result} -> {entry.name, code, result} end)
      end)

    example_block =
      if examples == [] do
        ""
      else
        examples_text =
          Enum.map_join(examples, "\n", fn {_name, code, result} ->
            "#{code}\n;; => #{result}"
          end)

        "\n```clojure\n#{examples_text}\n```"
      end

    """
    ## #{section}

    | Function | Signature | Description |
    |----------|-----------|-------------|
    #{rows}
    #{example_block}
    """
  end

  defp generate_audit(%{path: path, title: title, description: description, fetch: fetch} = spec) do
    entries = fetch.()

    counts = Enum.frequencies_by(entries, & &1.status)
    relevant = relevant_count(counts)
    coverage = coverage_percent(counts)

    source_file =
      if Map.has_key?(spec, :key),
        do: "priv/java_compat_audit.exs",
        else: "priv/function_audit.exs"

    rows =
      entries
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n", fn entry ->
        icon = status_icon(entry.status)
        "| `#{entry.name}` | #{icon} #{entry.status} | #{entry.description} | #{entry.notes} |"
      end)

    see_also =
      all_audits()
      |> Enum.reject(&(&1.path == path))
      |> Enum.map_join(" | ", fn %{path: p, title: t} ->
        name = t |> String.replace(" for PTC-Lisp", "")
        "[#{name}](#{Path.basename(p)})"
      end)

    function_reference_link =
      path
      |> Path.dirname()
      |> relative_link_to(Path.dirname(@function_ref_path), Path.basename(@function_ref_path))

    content = """
    <!-- Auto-generated — do not edit by hand -->
    # #{title}

    > **Warning:** This file is auto-generated by `mix ptc.gen_docs` from `#{source_file}`.
    > Manual edits will be overwritten. Edit `#{source_file}` instead.

    #{description}

    See also: [Function Reference](#{function_reference_link}) | [Namespace Coverage](index.md) | #{see_also}

    ## Summary

    Coverage excludes `not_relevant` entries: `supported / (supported + candidate + not_classified)`.

    | Status | Count |
    |--------|-------|
    | Supported | #{counts[:supported] || 0} |
    | Candidate | #{counts[:candidate] || 0} |
    | Not Relevant | #{counts[:not_relevant] || 0} |
    | Not Classified | #{counts[:not_classified] || 0} |
    | Relevant Target | #{relevant} |
    | Coverage | #{coverage} |
    | **Total** | **#{length(entries)}** |

    ## Details

    | Var | Status | Description | Notes |
    |-----|--------|-------------|-------|
    #{rows}
    """

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    Mix.shell().info("Generated #{path} (#{length(entries)} entries)")
  end

  defp generate_audit_index do
    audited_rows = Enum.map(all_audits(), &audited_index_row/1)
    non_audited_rows = Enum.map(@non_audited_namespaces, &non_audited_index_row/1)
    rows = audited_rows ++ non_audited_rows

    overall_counts =
      all_audits()
      |> Enum.flat_map(fn %{fetch: fetch} -> fetch.() end)
      |> Enum.frequencies_by(& &1.status)

    row_text =
      rows
      |> Enum.map_join("\n", fn row ->
        "| #{row.namespace} | #{row.scope} | #{row.target} | #{row.supported} | #{row.candidate} | #{row.not_relevant} | #{row.coverage} | #{row.audit} |"
      end)

    content = """
    <!-- Auto-generated — do not edit by hand -->
    # PTC-Lisp Namespace Coverage

    > **Warning:** This file is auto-generated by `mix ptc.gen_docs` from registry audit metadata.
    > Manual edits will be overwritten. Edit `priv/function_audit.exs`, `priv/java_compat_audit.exs`, or `lib/mix/tasks/ptc.gen_docs.ex` instead.

    This dashboard tracks how close each namespace is to its documented compatibility target and separates standard compatibility surfaces from PTC-specific extensions.
    Coverage is `supported / (supported + candidate + not_classified)` and excludes APIs marked `not_relevant`.
    Clojure rows target upstream Clojure namespaces. Java rows use a curated LLM-compatibility target from the Java standard library, not the full JDK surface.
    Rows marked `PTC extension` are intentionally outside Clojure/Java standard compatibility.

    ## Overall Audited Coverage

    | Metric | Count |
    |--------|-------|
    | Supported | #{overall_counts[:supported] || 0} |
    | Candidate | #{overall_counts[:candidate] || 0} |
    | Not Relevant | #{overall_counts[:not_relevant] || 0} |
    | Not Classified | #{overall_counts[:not_classified] || 0} |
    | Relevant Target | #{relevant_count(overall_counts)} |
    | Coverage | #{coverage_percent(overall_counts)} |

    ## Namespace Index

    | Namespace | Scope | Target | Supported | Candidate | Not Relevant | Coverage | Audit |
    |-----------|-------|--------|-----------|-----------|--------------|----------|-------|
    #{row_text}
    """

    File.mkdir_p!(Path.dirname(@audit_index_path))
    File.write!(@audit_index_path, content)
    Mix.shell().info("Generated #{@audit_index_path} (#{length(rows)} rows)")
  end

  defp audited_index_row(%{
         path: path,
         namespace: namespace,
         scope: scope,
         target: target,
         fetch: fetch
       }) do
    entries = fetch.()
    counts = Enum.frequencies_by(entries, & &1.status)

    %{
      namespace: namespace,
      scope: scope,
      target: "#{target} (#{length(entries)})",
      supported: counts[:supported] || 0,
      candidate: counts[:candidate] || 0,
      not_relevant: counts[:not_relevant] || 0,
      coverage: coverage_percent(counts),
      audit: "[audit](#{Path.basename(path)})"
    }
  end

  defp non_audited_index_row(%{namespace: namespace, scope: scope, target: target, audit: audit}) do
    %{
      namespace: namespace,
      scope: scope,
      target: target,
      supported: "N/A",
      candidate: "N/A",
      not_relevant: "N/A",
      coverage: "N/A",
      audit: audit_link(audit)
    }
  end

  defp audit_link(nil), do: "N/A"
  defp audit_link(path), do: "[audit](#{path})"

  defp relevant_count(counts) do
    (counts[:supported] || 0) + (counts[:candidate] || 0) + (counts[:not_classified] || 0)
  end

  defp coverage_percent(counts) do
    relevant = relevant_count(counts)

    if relevant == 0 do
      "N/A"
    else
      supported = counts[:supported] || 0
      "#{supported}/#{relevant} (#{Float.round(supported / relevant * 100, 1)}%)"
    end
  end

  defp generate_java_interop do
    entries = Registry.java_interop()

    by_class =
      entries
      |> Enum.group_by(& &1.class)
      |> Enum.sort_by(fn {class, _} -> class end)

    sections =
      Enum.map_join(by_class, "\n\n", fn {class, items} ->
        rows =
          items
          |> Enum.sort_by(& &1.name)
          |> Enum.map_join("\n", fn entry ->
            sigs = Enum.join(entry.signatures, ", ")
            kind = entry.kind |> to_string() |> String.capitalize()
            notes = if entry.notes != "", do: entry.notes, else: ""
            "| `#{entry.name}` | #{kind} | `#{sigs}` | #{entry.description} | #{notes} |"
          end)

        """
        ### #{class}

        | Name | Kind | Signature | Description | Notes |
        |------|------|-----------|-------------|-------|
        #{rows}
        """
      end)

    content = """
    <!-- Auto-generated — do not edit by hand -->
    # Java Interop Reference for PTC-Lisp

    > **Warning:** This file is auto-generated by `mix ptc.gen_docs` from `priv/functions.exs`.
    > Manual edits will be overwritten. Edit `priv/functions.exs` instead.

    PTC-Lisp emulates a subset of Java interop for LLM compatibility. These are **not** real JVM calls — they are BEAM-native implementations that mirror the Java API surface LLMs are trained on.

    #{length(entries)} interop entries across #{length(by_class)} classes.

    See also: [Function Reference](function-reference.md) | [PTC-Lisp Specification](ptc-lisp-specification.md) | [Namespace Coverage](conformance/index.md)

    #{sections}
    """

    File.write!(@interop_path, content)
    Mix.shell().info("Generated #{@interop_path} (#{length(entries)} entries)")
  end

  defp status_icon(:supported), do: "✅"
  defp status_icon(:candidate), do: "🔲"
  defp status_icon(:not_relevant), do: "❌"
  defp status_icon(_), do: "❓"

  defp relative_link_to(from_dir, to_dir, basename) do
    from_parts = path_parts(from_dir)
    to_parts = path_parts(to_dir)

    {from_rest, to_rest} = drop_common_prefix(from_parts, to_parts)
    up = List.duplicate("..", length(from_rest))
    Path.join(up ++ to_rest ++ [basename])
  end

  defp path_parts("."), do: []
  defp path_parts(path), do: String.split(path, "/", trim: true)

  defp drop_common_prefix([same | from_rest], [same | to_rest]),
    do: drop_common_prefix(from_rest, to_rest)

  defp drop_common_prefix(from_parts, to_parts), do: {from_parts, to_parts}
end
