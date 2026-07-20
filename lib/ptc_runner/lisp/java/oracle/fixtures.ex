defmodule PtcRunner.Lisp.Java.Oracle.Fixtures do
  @moduledoc """
  Validates structured Java oracle cases and their checked-in typed baseline.

  Cases identify manifest overloads and inputs without copying class, member,
  or descriptor metadata. The JVM baseline records the descriptor actually
  invoked by the pinned oracle, making descriptor drift independently visible.
  """

  alias PtcRunner.Lisp.Java.Oracle.Config
  alias PtcRunner.Lisp.Java.Surface

  @cases_resource "priv/java_interop_oracle_cases.exs"
  @baseline_resource "priv/java_interop_oracle_baseline.json"
  @external_resource @cases_resource
  @external_resource @baseline_resource

  @doc "Returns the structured source cases after manifest validation."
  @spec cases() :: [map()]
  def cases do
    fixtures = Code.eval_file(cases_path()) |> elem(0)
    validate_cases!(fixtures, Surface.manifest())
    fixtures
  end

  @doc "Returns the checked-in JVM baseline after full validation."
  @spec baseline() :: map()
  def baseline do
    baseline = baseline_path() |> File.read!() |> Jason.decode!() |> atomize_baseline()
    validate_baseline!(baseline, cases(), Surface.manifest())
    baseline
  end

  @doc false
  @spec cases_path() :: Path.t()
  def cases_path, do: Application.app_dir(:ptc_runner, @cases_resource)

  @doc false
  @spec baseline_path() :: Path.t()
  def baseline_path, do: Application.app_dir(:ptc_runner, @baseline_resource)

  @doc false
  @spec baseline_resource() :: Path.t()
  def baseline_resource, do: @baseline_resource

  @doc false
  @spec validate_cases!([map()], map()) :: :ok
  def validate_cases!(fixtures, manifest) when is_list(fixtures) do
    overloads = Map.new(manifest.overloads, &{&1.overload_id, &1})
    fixture_ids = Enum.map(fixtures, & &1.case_id)
    target_ids = Enum.map(fixtures, & &1.overload_id)

    ensure_unique!(fixture_ids, "fixture case IDs")

    expected_ids = Map.keys(overloads) |> MapSet.new()
    actual_ids = MapSet.new(target_ids)

    if actual_ids != expected_ids do
      raise ArgumentError,
            "Java oracle cases must cover every overload at least once; " <>
              "missing=#{inspect(MapSet.difference(expected_ids, actual_ids) |> MapSet.to_list())}, " <>
              "extra=#{inspect(MapSet.difference(actual_ids, expected_ids) |> MapSet.to_list())}"
    end

    Enum.each(fixtures, &validate_case!(&1, Map.fetch!(overloads, &1.overload_id)))
    :ok
  end

  @doc false
  @spec validate_baseline!(map(), [map()], map()) :: :ok
  def validate_baseline!(baseline, fixtures, manifest) do
    unless baseline.versions == Config.versions() do
      raise ArgumentError, "Java oracle baseline version metadata is stale"
    end

    unless baseline.environment == Config.environment() do
      raise ArgumentError, "Java oracle baseline environment metadata is stale"
    end

    unless baseline.provenance.clojure_version == Config.versions().clojure and
             baseline.provenance.java_runtime_version ==
               Config.versions().java.runtime <> "-LTS" and
             baseline.provenance.java_vendor == Config.versions().java.vendor and
             baseline.provenance.locale == Config.environment().locale and
             baseline.provenance.timezone == Config.environment().timezone do
      raise ArgumentError, "Java oracle baseline provenance is stale"
    end

    overloads = Map.new(manifest.overloads, &{Atom.to_string(&1.overload_id), &1})

    jvm_fixture_ids =
      fixtures
      |> Enum.filter(&(&1.oracle == :jvm))
      |> MapSet.new(&Atom.to_string(&1.overload_id))

    outcome_ids = MapSet.new(baseline.outcomes, & &1.overload_id)
    outcome_case_ids = MapSet.new(baseline.outcomes, & &1.case_id)

    fixture_case_ids =
      fixtures
      |> Enum.filter(&(&1.oracle == :jvm))
      |> MapSet.new(& &1.case_id)

    ensure_unique!(Enum.map(baseline.outcomes, & &1.case_id), "baseline case IDs")

    unless outcome_ids == jvm_fixture_ids and outcome_case_ids == fixture_case_ids do
      raise ArgumentError, "Java oracle baseline must cover every JVM fixture exactly"
    end

    fixtures_by_case_id =
      fixtures
      |> Enum.filter(&(&1.oracle == :jvm))
      |> Map.new(&{&1.case_id, &1})

    Enum.each(baseline.outcomes, fn outcome ->
      fixture = Map.fetch!(fixtures_by_case_id, outcome.case_id)
      overload = Map.fetch!(overloads, outcome.overload_id)

      unless outcome.overload_id == Atom.to_string(fixture.overload_id) do
        raise ArgumentError, "Java oracle baseline target drift for #{outcome.case_id}"
      end

      unless outcome.descriptor == overload.descriptor do
        raise ArgumentError,
              "Java oracle baseline descriptor drift for #{outcome.overload_id}: " <>
                "#{inspect(outcome.descriptor)} != #{inspect(overload.descriptor)}"
      end

      unless outcome.expected == fixture.expected do
        raise ArgumentError,
              "Java oracle baseline typed outcome drift for #{outcome.overload_id}"
      end
    end)

    :ok
  end

  defp validate_case!(fixture, overload) do
    expected_oracle = if overload.attestation == :jvm, do: :jvm, else: :ptc_only

    unless fixture.oracle == expected_oracle do
      raise ArgumentError,
            "fixture #{fixture.case_id} oracle must be #{inspect(expected_oracle)}"
    end

    validate_subsets!(fixture, expected_oracle)

    unless fixture.divergence_ids == overload.divergence_ids do
      raise ArgumentError,
            "fixture #{fixture.case_id} divergence IDs do not match manifest"
    end

    validate_expected!(fixture, overload)

    unless length(fixture.invocation.arguments) == overload.arity do
      raise ArgumentError,
            "fixture #{fixture.case_id} argument count does not match manifest arity"
    end

    validate_arguments!(fixture, overload)
    validate_receiver!(fixture, overload)
  end

  defp validate_arguments!(fixture, overload) do
    fixture.invocation.arguments
    |> Enum.zip(overload.arguments)
    |> Enum.each(fn {%{type: actual}, expected} ->
      unless compatible_argument_type?(actual, expected) do
        raise ArgumentError,
              "fixture #{fixture.case_id} argument type #{inspect(actual)} " <>
                "does not match #{inspect(expected)}"
      end
    end)
  end

  defp compatible_argument_type?(:string, :char_sequence), do: true
  defp compatible_argument_type?(type, :temporal) when type in [:instant, :local_date], do: true

  defp compatible_argument_type?(type, :ptc_temporal)
       when type in [:date, :instant, :local_date],
       do: true

  defp compatible_argument_type?(type, type), do: true
  defp compatible_argument_type?(_actual, _expected), do: false

  defp validate_expected!(%{expected: %{status: :ok, type: type}}, %{return: type}), do: :ok

  defp validate_expected!(%{expected: %{status: :error, type: :error, value: value}}, _overload)
       when is_binary(value),
       do: :ok

  defp validate_expected!(fixture, _overload) do
    raise ArgumentError,
          "fixture #{fixture.case_id} expected status/type does not match its manifest contract"
  end

  defp validate_subsets!(%{subsets: subsets} = fixture, :jvm) do
    unless :implemented in subsets and Enum.all?(subsets, &(&1 in [:implemented, :fast])) do
      raise ArgumentError,
            "fixture #{fixture.case_id} must use the implemented JVM subset and optional fast subset"
    end
  end

  defp validate_subsets!(%{subsets: [:ptc_only]}, _oracle), do: :ok

  defp validate_subsets!(fixture, :ptc_only) do
    raise ArgumentError, "fixture #{fixture.case_id} must use only the ptc_only subset"
  end

  defp validate_receiver!(%{invocation: %{receiver: nil}}, %{receiver: nil}), do: :ok

  defp validate_receiver!(%{invocation: %{receiver: %{type: type}}}, %{receiver: type}), do: :ok

  defp validate_receiver!(fixture, _overload) do
    raise ArgumentError, "fixture #{fixture.case_id} receiver does not match manifest"
  end

  defp ensure_unique!(values, label) do
    if Enum.uniq(values) != values do
      raise ArgumentError, "duplicate #{label}"
    end
  end

  defp atomize_baseline(baseline) do
    %{
      versions: %{
        java: %{
          distribution: get_in(baseline, ["versions", "java", "distribution"]),
          vendor: get_in(baseline, ["versions", "java", "vendor"]),
          feature: get_in(baseline, ["versions", "java", "feature"]),
          runtime: get_in(baseline, ["versions", "java", "runtime"]),
          setup_java: get_in(baseline, ["versions", "java", "setup_java"]),
          mise: get_in(baseline, ["versions", "java", "mise"])
        },
        clojure: get_in(baseline, ["versions", "clojure"]),
        babashka: get_in(baseline, ["versions", "babashka"])
      },
      environment: %{
        locale: get_in(baseline, ["environment", "locale"]),
        timezone: get_in(baseline, ["environment", "timezone"])
      },
      provenance: %{
        oracle: get_in(baseline, ["provenance", "oracle"]),
        command: get_in(baseline, ["provenance", "command"]),
        java_runtime_version: get_in(baseline, ["provenance", "java_runtime_version"]),
        java_vendor: get_in(baseline, ["provenance", "java_vendor"]),
        clojure_version: get_in(baseline, ["provenance", "clojure_version"]),
        locale: get_in(baseline, ["provenance", "locale"]),
        timezone: get_in(baseline, ["provenance", "timezone"])
      },
      outcomes: Enum.map(baseline["outcomes"], &atomize_outcome/1)
    }
  end

  defp atomize_outcome(outcome) do
    %{
      case_id: outcome["case_id"],
      overload_id: outcome["overload_id"],
      descriptor: outcome["descriptor"],
      expected: %{
        status: String.to_existing_atom(get_in(outcome, ["expected", "status"])),
        type: String.to_existing_atom(get_in(outcome, ["expected", "type"])),
        value: get_in(outcome, ["expected", "value"])
      }
    }
  end
end
