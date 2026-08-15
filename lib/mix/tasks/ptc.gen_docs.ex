defmodule Mix.Tasks.Ptc.GenDocs do
  @shortdoc "Generate function reference and audit docs from registry"
  @moduledoc """
  Generates documentation from `priv/functions.exs` (ordinary implemented
  functions), `priv/function_audit.exs` (Clojure parity triage notes), and
  `priv/java_interop.exs` (bounded Java surface and presentation metadata):

  1. `docs/function-reference.md` — all implemented functions grouped by section
  2. `docs/conformance/index.md` — namespace coverage dashboard
  3. `docs/conformance/*-audit.md` — Clojure and Java compatibility audits
  4. `docs/java-interop.md` — bounded Java interop reference
  5. `priv/schemas/ptc-host-config.schema.json` — host-installation JSON Schema
  6. `priv/schemas/ptc-application-manifest.schema.json` — manifest JSON Schema
  7. `priv/schemas/ptc-command-envelope-v2.schema.json` — command envelope JSON Schema
  8. `priv/schemas/ptc-project-config.schema.json` — project launch JSON Schema
  9. `docs/kernel-limits-reference.md` — Kernel run-limit meanings and metadata

  ## Usage

      mix ptc.gen_docs
      mix ptc.gen_docs --check

  `--check` verifies the checked-in files without rewriting them.
  """
  use Mix.Task

  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Lisp.Java.Surface
  alias PtcRunner.Lisp.Registry

  @function_ref_path "docs/function-reference.md"
  @limit_reference_path "docs/kernel-limits-reference.md"
  @audit_index_path "docs/conformance/index.md"
  @host_schema_path "priv/schemas/ptc-host-config.schema.json"
  @manifest_schema_path "priv/schemas/ptc-application-manifest.schema.json"
  @command_schema_path "priv/schemas/ptc-command-envelope-v2.schema.json"
  @project_schema_path "priv/schemas/ptc-project-config.schema.json"
  @generated_schema_paths [
    @host_schema_path,
    @manifest_schema_path,
    @command_schema_path,
    @project_schema_path
  ]

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
    %{namespace: "`json/`", scope: "PTC extension", target: "PTC JSON helpers", audit: nil}
  ]

  @repl_environment_support [
    %{
      command: "`(quote symbol)`, `'symbol`",
      status: "partial",
      scope: "Core syntax",
      notes: "Symbol references only; quoted collections and syntax quote are not supported"
    }
  ]

  @repl_candidates [
    {"User var discovery", "Let sessions inspect `def`/`defn` bindings and captured docstrings"},
    {"Examples/source snippets", "Expose examples only where they improve model repair"}
  ]

  @interop_path "docs/java-interop.md"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    check? = "--check" in args

    if check? do
      check_java_audit_path_set!()
      check_generated_schema_path_set!()
    end

    validate_limit_catalog!()

    generate_limit_reference(check?)
    generate_function_reference(check?)
    Enum.each(all_audits(), &generate_audit(&1, check?))
    generate_audit_index(check?)
    generate_java_interop(check?)
    generate_host_schema(check?)
    generate_manifest_schema(check?)
    generate_command_schema(check?)
    generate_project_schema(check?)
  end

  defp validate_limit_catalog! do
    Limits.defaults()
    |> Map.from_struct()
    |> Map.keys()
    |> LimitCatalog.validate_fields!()
  end

  defp generate_limit_reference(check?) do
    manifest_rows = limit_rows(:manifest_narrowable)
    installed_rows = limit_rows(:installed_only)

    content = """
    <!-- Auto-generated — do not edit by hand -->
    # Kernel limits reference

    > **Warning:** This file is auto-generated by `mix ptc.gen_docs` from the Kernel limit catalog.
    > Manual edits will be overwritten. Edit `lib/ptc_runner/kernel/limit_catalog.ex` instead.

    Every limit is a positive enforced ceiling; there is no disabled or infinite form. A host installs the outer values. An application may request a lower value only for the application-narrowable rows, and the installed ceiling still wins when it is lower than the ordinary effective default.

    Time values are milliseconds. Heap values are BEAM process heap words, not bytes. The catalog range is the accepted structural range; practical installations should choose ceilings appropriate to their resources and trust boundary.

    ## Application-narrowable limits

    | Name | Meaning | Unit | Effective default | Installed default | Inclusive range |
    | --- | --- | --- | ---: | ---: | ---: |
    #{manifest_rows}

    ## Installed-only limits

    These operational timeouts belong only to the host document. A manifest cannot declare them.

    | Name | Meaning | Unit | Installed default | Inclusive range | Effective identity |
    | --- | --- | --- | ---: | ---: | --- |
    #{installed_rows}

    ## Related guides

    - [Manifests and capabilities](guides/manifests-and-capabilities.md#narrow-installed-limits) explains application narrowing.
    - [Host configuration](guides/host-configuration.md#set-installed-ceilings) explains outer installed policy.
    - [Building agents](guides/building-agents.md#configure-the-loop) distinguishes agent-loop options from Kernel limits.
    """

    write_or_check!(@limit_reference_path, content, check?)
    report_generation(@limit_reference_path, length(LimitCatalog.rows()), "limits", check?)
  end

  defp limit_rows(:manifest_narrowable) do
    :manifest_narrowable
    |> LimitCatalog.rows()
    |> Enum.map_join("\n", fn row ->
      "| `#{row.name}` | #{row.description} | #{limit_unit(row.unit)} | " <>
        "#{format_integer(row.compiled_default)} | #{format_integer(row.installed_default)} | " <>
        "#{format_integer(row.minimum)}–#{format_integer(row.maximum)} |"
    end)
  end

  defp limit_rows(:installed_only) do
    :installed_only
    |> LimitCatalog.rows()
    |> Enum.map_join("\n", fn row ->
      identity = if row.identity, do: "yes", else: "no"

      "| `#{row.name}` | #{row.description} | #{limit_unit(row.unit)} | " <>
        "#{format_integer(row.installed_default)} | " <>
        "#{format_integer(row.minimum)}–#{format_integer(row.maximum)} | #{identity} |"
    end)
  end

  defp limit_unit(:milliseconds), do: "milliseconds"
  defp limit_unit(:heap_words), do: "BEAM heap words"
  defp limit_unit(:bytes), do: "bytes"
  defp limit_unit(:count), do: "count"

  defp format_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp generate_host_schema(check?) do
    {:ok, encoded} = HostConfig.schema() |> DeterministicJSON.encode()
    write_or_check!(@host_schema_path, encoded <> "\n", check?)
    report_generation(@host_schema_path, 1, "schema", check?)
  end

  defp generate_manifest_schema(check?) do
    {:ok, encoded} = Manifest.schema() |> DeterministicJSON.encode()
    write_or_check!(@manifest_schema_path, encoded <> "\n", check?)
    report_generation(@manifest_schema_path, 1, "schema", check?)
  end

  defp generate_command_schema(check?) do
    {:ok, encoded} = CommandContract.schema() |> DeterministicJSON.encode()
    write_or_check!(@command_schema_path, encoded <> "\n", check?)
    report_generation(@command_schema_path, 1, "schema", check?)
  end

  defp generate_project_schema(check?) do
    {:ok, encoded} = ProjectConfig.schema() |> DeterministicJSON.encode()
    write_or_check!(@project_schema_path, encoded <> "\n", check?)
    report_generation(@project_schema_path, 1, "schema", check?)
  end

  defp check_java_audit_path_set! do
    expected = Enum.map(Surface.audit_specs(), & &1.path)
    actual = generated_java_audit_paths()

    case java_audit_path_drift(expected, actual) do
      %{missing: [], orphaned: []} ->
        :ok

      drift ->
        Mix.raise("Generated Java audit path set is stale: #{inspect(drift)}")
    end
  end

  defp check_generated_schema_path_set! do
    case generated_path_drift(@generated_schema_paths, generated_schema_paths()) do
      %{missing: [], orphaned: []} ->
        :ok

      drift ->
        Mix.raise("Generated schema path set is stale: #{inspect(drift)}")
    end
  end

  @doc false
  def generated_schema_paths(root \\ ".") do
    root
    |> Path.join("priv/schemas/ptc-*.schema.json")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc false
  def generated_path_drift(expected, actual) do
    expected = MapSet.new(expected)
    actual = MapSet.new(actual)

    %{
      missing: expected |> MapSet.difference(actual) |> Enum.sort(),
      orphaned: actual |> MapSet.difference(expected) |> Enum.sort()
    }
  end

  @doc false
  def generated_java_audit_paths(root \\ ".") do
    root
    |> Path.join("docs/conformance/**/*.md")
    |> Path.wildcard()
    |> Enum.filter(&generated_java_audit?/1)
    |> Enum.sort()
  end

  @doc false
  def java_audit_path_drift(expected, actual) do
    generated_path_drift(expected, actual)
  end

  defp generated_java_audit?(path) do
    case File.read(path) do
      {:ok, content} ->
        String.starts_with?(content, "<!-- Auto-generated") and
          String.contains?(content, "from `priv/java_interop.exs`")

      {:error, _reason} ->
        false
    end
  end

  defp all_audits do
    clojure_audits = Enum.reject(@audits, &(&1.path == "docs/conformance/java-math-audit.md"))

    clojure_audits ++
      Enum.map(Surface.audit_specs(), fn spec ->
        spec
        |> Map.put(:namespace, spec.namespace_label)
        |> Map.put(:fetch, fn -> Surface.audit(spec.key) end)
      end)
  end

  defp generate_function_reference(check?) do
    entries = Registry.implemented()

    sections =
      entries
      |> Enum.group_by(& &1.section)
      |> Enum.sort_by(fn {section, _} -> section_order(section) end)

    content = """
    <!-- Auto-generated — do not edit by hand -->
    # PTC-Lisp Function Reference

    > **Warning:** This file is auto-generated by `mix ptc.gen_docs` from `priv/functions.exs` and `priv/java_interop.exs`.
    > Manual edits will be overwritten. Edit those source manifests instead.

    #{length(entries)} functions and special forms.

    `*` marks PtcRunner extensions without a `clojure.core` equivalent.

    See also: [PTC-Lisp Specification](ptc-lisp-specification.md) | [Clojure Conformance Gaps](clojure-conformance-gaps.md) | [Namespace Coverage](conformance/index.md)

    ## Table of Contents

    #{toc(sections)}

    #{Enum.map_join(sections, "\n\n", &render_section/1)}
    """

    write_or_check!(@function_ref_path, String.trim_trailing(content) <> "\n", check?)
    report_generation(@function_ref_path, length(entries), "entries", check?)
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
  defp section_order("Discovery"), do: 8
  defp section_order("Agent Control"), do: 9
  defp section_order("String Functions"), do: 10
  defp section_order("Set Operations"), do: 11
  defp section_order("Regex Functions"), do: 12
  defp section_order("Math Functions"), do: 13
  defp section_order("Interop"), do: 14
  defp section_order("JSON"), do: 15
  defp section_order("MCP"), do: 16
  defp section_order(_), do: 99

  defp render_section({section, entries}) do
    rows =
      entries
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n", fn entry ->
        sigs = Enum.join(entry.signatures, ", ")
        ext = if entry.ptc_extension?, do: " *", else: ""
        "| `#{entry.name}`#{ext} | `#{sigs}` | #{description_cell(entry)} |"
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

  defp description_cell(entry) do
    caveat = entry[:notes] || entry[:divergences]
    if caveat, do: "#{entry.description} — #{caveat}", else: entry.description
  end

  defp generate_audit(
         %{path: path, title: title, description: description, fetch: fetch} = spec,
         check?
       ) do
    entries = fetch.()

    counts = Enum.frequencies_by(entries, & &1.status)
    relevant = relevant_count(counts)
    coverage = coverage_percent(counts)

    source_file =
      if Map.has_key?(spec, :key), do: "priv/java_interop.exs", else: "priv/function_audit.exs"

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

    write_or_check!(path, content, check?)
    report_generation(path, length(entries), "entries", check?)
  end

  defp generate_audit_index(check?) do
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
    > Manual edits will be overwritten. Edit `priv/function_audit.exs`, `priv/java_interop.exs`, or `lib/mix/tasks/ptc.gen_docs.ex` instead.

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

    ## REPL Environment Support

    #{repl_environment_support_table()}

    ## REPL Candidates

    #{repl_candidates_table()}
    """

    write_or_check!(@audit_index_path, content, check?)
    report_generation(@audit_index_path, length(rows), "rows", check?)
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

  defp repl_environment_support_table do
    rows =
      Enum.map_join(@repl_environment_support, "\n", fn row ->
        "| #{row.command} | #{row.status} | #{row.scope} | #{row.notes} |"
      end)

    """
    | Command | Status | Scope | Notes |
    |---------|--------|-------|-------|
    #{rows}
    """
  end

  defp repl_candidates_table do
    rows =
      Enum.map_join(@repl_candidates, "\n", fn {candidate, why} ->
        "| #{candidate} | #{why} |"
      end)

    """
    | Candidate | Why |
    |-----------|-----|
    #{rows}
    """
  end

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

  defp generate_java_interop(check?) do
    entries = Registry.java_interop()

    linked_class_count =
      entries
      |> Enum.flat_map(& &1.reference_ids)
      |> Enum.map(fn reference_id ->
        {:ok, reference} = Surface.fetch_reference(reference_id)
        reference.class_id
      end)
      |> Enum.uniq()
      |> length()

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

    > **Warning:** This file is auto-generated by `mix ptc.gen_docs` from `priv/java_interop.exs`.
    > Manual edits will be overwritten. Edit `priv/java_interop.exs` instead.

    PTC-Lisp emulates a subset of Java interop for LLM compatibility. These are **not** real JVM calls — they are BEAM-native implementations that mirror the Java API surface LLMs are trained on.

    #{length(entries)} interop entries covering #{linked_class_count} Java classes in #{length(by_class)} presentation groups.

    See also: [Function Reference](function-reference.md) | [PTC-Lisp Specification](ptc-lisp-specification.md) | [Namespace Coverage](conformance/index.md)

    #{sections}
    """

    write_or_check!(@interop_path, content, check?)
    report_generation(@interop_path, length(entries), "entries", check?)
  end

  defp write_or_check!(path, expected, true) do
    case File.read(path) do
      {:ok, ^expected} -> :ok
      {:ok, _stale} -> Mix.raise("Generated file is stale: #{path}")
      {:error, reason} -> Mix.raise("Cannot verify generated file #{path}: #{reason}")
    end
  end

  defp write_or_check!(path, content, false) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp report_generation(path, count, unit, true),
    do: Mix.shell().info("Verified #{path} (#{count} #{unit})")

  defp report_generation(path, count, unit, false),
    do: Mix.shell().info("Generated #{path} (#{count} #{unit})")

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
