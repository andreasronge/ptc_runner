defmodule Mix.Tasks.Ptc.ConformanceReport do
  @shortdoc "Report PTC-Lisp conformance case coverage"
  @moduledoc """
  Prints a coverage report for explicit PTC-Lisp conformance cases.

      mix ptc.conformance_report
      mix ptc.conformance_report --write-inventory
      mix ptc.conformance_report --check-inventory

  The inventory is built from audit metadata, not from generated docs.
  `--check-inventory` also requires every supported Java target to have an
  explicit conformance case.
  """

  use Mix.Task

  alias PtcRunner.Lisp.Java.Surface
  alias PtcRunner.Lisp.Registry

  @case_files [
    "test/support/lisp_conformance_cases/manual.ex"
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    load_case_files()

    inventory = inventory()
    cases = conformance_cases()
    covered = covered_keys(cases)

    inventory_content =
      Jason.encode!(ordered_inventory(inventory), pretty: true) <> "\n"

    cond do
      "--write-inventory" in args ->
        File.write!("conformance_inventory.json", inventory_content)
        Mix.shell().info("Wrote conformance_inventory.json")

      "--check-inventory" in args ->
        check_inventory!(inventory_content)
        validate_supported_java_coverage!(inventory, cases)

      true ->
        :ok
    end

    print_summary(inventory, cases, covered)
  end

  defp check_inventory!(expected) do
    case File.read("conformance_inventory.json") do
      {:ok, ^expected} ->
        Mix.shell().info("Verified conformance_inventory.json")

      {:ok, _stale} ->
        Mix.raise("Generated conformance inventory is stale: conformance_inventory.json")

      {:error, reason} ->
        Mix.raise("Cannot verify conformance_inventory.json: #{reason}")
    end
  end

  @doc false
  @spec validate_supported_java_coverage!([map()], [map()]) :: :ok
  def validate_supported_java_coverage!(inventory, cases) do
    case missing_supported_java_cases(inventory, cases) do
      [] ->
        :ok

      missing ->
        labels = Enum.map_join(missing, ", ", &"#{&1.namespace}/#{&1.symbol}")
        Mix.raise("Supported Java entries lack explicit conformance cases: #{labels}")
    end
  end

  @doc false
  @spec missing_supported_java_cases([map()], [map()]) :: [map()]
  def missing_supported_java_cases(inventory, cases) do
    covered =
      cases
      |> Enum.reject(&(&1.policy == :unsupported))
      |> covered_keys()

    inventory
    |> Enum.filter(&(&1.compatibility_target == "Java" and &1.status == :supported))
    |> Enum.reject(&covered?(&1, covered))
  end

  defp load_case_files do
    Enum.each(@case_files, fn file ->
      if File.exists?(file), do: Code.require_file(file)
    end)
  end

  defp conformance_cases do
    module = PtcRunner.TestSupport.LispConformanceCases.Manual

    if Code.ensure_loaded?(module) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(module, :all, [])
    else
      []
    end
  end

  defp inventory do
    clojure_inventory() ++ java_inventory()
  end

  defp clojure_inventory do
    [
      {"clojure.core", Registry.clojure_core_audit()},
      {"clojure.string", Registry.clojure_string_audit()},
      {"clojure.set", Registry.clojure_set_audit()},
      {"clojure.walk", Registry.clojure_walk_audit()}
    ]
    |> Enum.flat_map(fn {namespace, entries} ->
      Enum.map(entries, &inventory_entry(namespace, &1, "Clojure"))
    end)
  end

  defp java_inventory do
    Surface.audit_specs()
    |> Enum.flat_map(fn spec ->
      spec.key
      |> Surface.audit()
      |> Enum.map(fn entry ->
        entry = Map.update!(entry, :name, &(Map.get(spec, :conformance_prefix, "") <> &1))
        inventory_entry(spec.namespace, entry, "Java")
      end)
    end)
  end

  defp inventory_entry(namespace, entry, target) do
    %{
      namespace: namespace,
      symbol: entry.name,
      status: entry.status,
      compatibility_target: target,
      notes: Map.get(entry, :notes, "")
    }
  end

  defp ordered_inventory(inventory) do
    Enum.map(inventory, fn entry ->
      Jason.OrderedObject.new(
        status: entry.status,
        symbol: entry.symbol,
        namespace: entry.namespace,
        compatibility_target: entry.compatibility_target,
        notes: entry.notes
      )
    end)
  end

  defp covered_keys(cases) do
    cases
    |> Enum.flat_map(fn case_data ->
      Enum.map(Map.get(case_data, :vars, []), &{case_data.namespace, &1})
    end)
    |> MapSet.new()
  end

  defp print_summary(inventory, cases, covered) do
    supported = Enum.filter(inventory, &(&1.status == :supported))
    candidates = Enum.filter(inventory, &(&1.status == :candidate))
    not_relevant = Enum.filter(inventory, &(&1.status == :not_relevant))
    supported_covered = Enum.count(supported, &covered?(&1, covered))
    candidate_covered = Enum.count(candidates, &covered?(&1, covered))
    documented_ids = documented_gap_div_ids()
    case_ids = case_gap_div_ids(cases)

    Mix.shell().info("")
    Mix.shell().info("=== PTC-Lisp Conformance Coverage ===")
    Mix.shell().info("Cases: #{length(cases)}")
    Mix.shell().info("Inventory entries: #{length(inventory)}")
    Mix.shell().info("Supported entries: #{length(supported)}")
    Mix.shell().info("Candidate entries: #{length(candidates)}")
    Mix.shell().info("Not relevant entries: #{length(not_relevant)}")
    Mix.shell().info("Supported with cases: #{supported_covered}/#{length(supported)}")
    Mix.shell().info("Candidates with cases: #{candidate_covered}/#{length(candidates)}")
    Mix.shell().info("")

    print_namespace_summary(supported, covered)
    print_missing_supported(supported, covered)
    print_missing_candidates(candidates, covered)
    print_policy_summary(cases)
    print_gap_div_summary(documented_ids, case_ids)
  end

  defp print_namespace_summary(supported, covered) do
    Mix.shell().info("By namespace:")

    supported
    |> Enum.group_by(& &1.namespace)
    |> Enum.sort_by(fn {namespace, _entries} -> namespace end)
    |> Enum.each(fn {namespace, entries} ->
      count = Enum.count(entries, &covered?(&1, covered))
      Mix.shell().info("  #{namespace}: #{count}/#{length(entries)} supported entries covered")
    end)
  end

  defp print_missing_supported(supported, covered) do
    Mix.shell().info("")
    Mix.shell().info("Supported entries without explicit cases:")

    supported
    |> Enum.reject(&covered?(&1, covered))
    |> Enum.take(80)
    |> Enum.each(fn entry ->
      Mix.shell().info("  #{entry.namespace}/#{entry.symbol}")
    end)
  end

  defp print_missing_candidates(candidates, covered) do
    Mix.shell().info("")
    Mix.shell().info("Candidate entries without explicit cases:")

    candidates
    |> Enum.reject(&covered?(&1, covered))
    |> Enum.take(80)
    |> Enum.each(fn entry ->
      Mix.shell().info("  #{entry.namespace}/#{entry.symbol}")
    end)
  end

  defp print_policy_summary(cases) do
    Mix.shell().info("")
    Mix.shell().info("Cases by policy:")

    cases
    |> Enum.frequencies_by(&policy_name/1)
    |> Enum.sort_by(fn {policy, _count} -> policy end)
    |> Enum.each(fn {policy, count} -> Mix.shell().info("  #{policy}: #{count}") end)
  end

  @spec print_gap_div_summary([String.t()], [String.t()]) :: :ok
  defp print_gap_div_summary(documented_ids, case_ids) do
    missing_cases = documented_ids -- case_ids
    undocumented_cases = case_ids -- documented_ids
    covered_count = Enum.count(documented_ids, &(&1 in case_ids))

    Mix.shell().info("")

    Mix.shell().info(
      "Documented GAP/DIV ids with regression cases: #{covered_count}/#{length(documented_ids)}"
    )

    print_id_list("Documented GAP/DIV ids without regression cases:", missing_cases)
    print_id_list("Regression GAP/DIV ids not documented:", undocumented_cases)
  end

  defp print_id_list(label, ids) do
    Mix.shell().info(label)

    ids
    |> Enum.sort()
    |> Enum.take(80)
    |> Enum.each(fn id -> Mix.shell().info("  #{id}") end)
  end

  defp covered?(entry, covered) do
    MapSet.member?(covered, {entry.namespace, entry.symbol})
  end

  defp policy_name(%{policy: {:bug, _id}}), do: "bug"
  defp policy_name(%{policy: {:diverges, _id}}), do: "diverges"
  defp policy_name(%{policy: policy}), do: to_string(policy)

  @spec case_gap_div_ids([map()]) :: [String.t()]
  defp case_gap_div_ids(cases) do
    cases
    |> Enum.flat_map(fn
      %{policy: {:bug, id}} = case_data ->
        [id | Map.get(case_data, :regression_ids, [])]

      %{policy: {:diverges, id}} = case_data ->
        [id | Map.get(case_data, :regression_ids, [])]

      case_data ->
        Map.get(case_data, :regression_ids, [])
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec documented_gap_div_ids() :: [String.t()]
  defp documented_gap_div_ids do
    case File.read("docs/clojure-conformance-gaps.md") do
      {:ok, content} ->
        ~r/^### ((?:GAP-[A-Z]\d+)|(?:DIV-\d+)):/m
        |> Regex.scan(content, capture: :all_but_first)
        |> Enum.map(fn [id] -> id end)
        |> Enum.uniq()
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end
end
