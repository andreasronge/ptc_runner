defmodule PtcRunner.TestSupport.LispConformanceRunner do
  @moduledoc """
  Executes explicit PTC-Lisp conformance cases against PTC-Lisp and Babashka.
  """

  alias PtcRunner.Lisp.ClojureValidator
  alias PtcRunner.Lisp.Keyword, as: LispKeyword

  @default_ptc_timeout 5_000
  @default_clojure_timeout 5_000

  @type outcome :: {:ok, term()} | {:error, term()}
  @type result ::
          {:pass, map()}
          | {:fail, map()}
          | {:skip, map()}

  @doc """
  Runs one conformance case and classifies the result according to its policy.
  """
  @spec run_case(map(), keyword()) :: result()
  def run_case(case_data, opts \\ [])

  def run_case(%{policy: :unsupported} = case_data, _opts) do
    {:skip, Map.put(case_data, :skip_reason, Map.get(case_data, :reason, "unsupported"))}
  end

  def run_case(case_data, opts) do
    ptc = run_ptc(case_data, opts)

    case Map.fetch!(case_data, :policy) do
      :match ->
        clojure = run_clojure(case_data, opts)
        classify_match(case_data, ptc, clojure)

      {:diverges, div_id} ->
        clojure = run_clojure(case_data, opts)
        classify_divergence(case_data, div_id, ptc, clojure)

      {:bug, gap_id} ->
        clojure = run_clojure(case_data, opts)
        classify_known_bug(case_data, gap_id, ptc, clojure)

      :ptc_extension ->
        classify_ptc_extension(case_data, ptc)

      :unknown ->
        clojure = run_clojure(case_data, opts)
        classify_unknown(case_data, ptc, clojure)
    end
  end

  @doc """
  Runs multiple cases and returns grouped results.
  """
  @spec run_cases([map()], keyword()) :: %{passed: [map()], failed: [map()], skipped: [map()]}
  def run_cases(cases, opts \\ []) do
    Enum.reduce(cases, %{passed: [], failed: [], skipped: []}, fn case_data, acc ->
      case run_case(case_data, opts) do
        {:pass, details} -> update_in(acc.passed, &[details | &1])
        {:fail, details} -> update_in(acc.failed, &[details | &1])
        {:skip, details} -> update_in(acc.skipped, &[details | &1])
      end
    end)
    |> Map.update!(:passed, &Enum.reverse/1)
    |> Map.update!(:failed, &Enum.reverse/1)
    |> Map.update!(:skipped, &Enum.reverse/1)
  end

  @doc """
  Returns a stable, comparison-oriented normalization of PTC/Clojure values.
  """
  @spec normalize(term()) :: term()
  def normalize(%MapSet{} = set) do
    set
    |> MapSet.to_list()
    |> Enum.map(&normalize/1)
    |> Enum.sort_by(&inspect/1)
  end

  def normalize(%LispKeyword{name: name}), do: name
  def normalize(%PtcRunner.Lisp.Format.Var{name: name}), do: "#'#{name}"
  def normalize(%Date{} = date), do: Date.to_iso8601(date)
  def normalize(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def normalize(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  def normalize(%Time{} = time), do: Time.to_iso8601(time)

  def normalize(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {normalize_key(key), normalize(value)} end)
    |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
    |> Map.new()
  end

  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  def normalize(:infinity), do: :infinity
  def normalize(:negative_infinity), do: :negative_infinity
  def normalize(:nan), do: :nan

  def normalize(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: ":#{value}"

  def normalize(value) when is_float(value) do
    if value != value, do: :nan, else: value
  end

  def normalize("Infinity"), do: :infinity
  def normalize("##Inf"), do: :infinity
  def normalize("-Infinity"), do: :negative_infinity
  def normalize("##-Inf"), do: :negative_infinity
  def normalize("NaN"), do: :nan
  def normalize("##NaN"), do: :nan

  def normalize("#object[java.time." <> _ = object_string) do
    case Regex.run(~r/"([^"]+)"\]$/, object_string) do
      [_match, rendered] -> rendered
      nil -> object_string
    end
  end

  def normalize(value), do: value

  defp normalize_key(%LispKeyword{name: name}), do: name
  defp normalize_key(key) when is_boolean(key), do: to_string(key)
  defp normalize_key(key) when is_atom(key), do: ":#{key}"
  defp normalize_key(key), do: normalize(key)

  defp run_ptc(case_data, opts) do
    context = Keyword.get(opts, :context, Map.get(case_data, :context, %{}))
    memory = Keyword.get(opts, :memory, Map.get(case_data, :memory, %{}))
    timeout = Keyword.get(opts, :ptc_timeout, @default_ptc_timeout)

    run_with_timeout(
      fn ->
        case PtcRunner.Lisp.run(case_data.form, context: context, memory: memory) do
          {:ok, step} -> {:ok, step.return}
          {:error, step} -> {:error, step.fail}
        end
      end,
      timeout,
      :ptc_timeout
    )
  end

  defp run_clojure(case_data, opts) do
    context = Keyword.get(opts, :context, Map.get(case_data, :context, %{}))
    memory = Keyword.get(opts, :memory, Map.get(case_data, :memory, %{}))
    timeout = Keyword.get(opts, :clojure_timeout, @default_clojure_timeout)
    ClojureValidator.execute(case_data.form, context: context, memory: memory, timeout: timeout)
  end

  defp run_with_timeout(fun, timeout, reason) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, %{reason: reason, message: "timed out after #{timeout}ms", details: %{}}}
    end
  end

  defp classify_match(case_data, {:ok, ptc_value} = ptc, {:ok, clj_value} = clojure) do
    if normalize(ptc_value) == normalize(clj_value) do
      {:pass, details(case_data, ptc, clojure)}
    else
      fail(case_data, ptc, clojure, :value_mismatch)
    end
  end

  defp classify_match(case_data, {:error, _} = ptc, {:error, _} = clojure) do
    {:pass, details(case_data, ptc, clojure)}
  end

  defp classify_match(case_data, ptc, clojure),
    do: fail(case_data, ptc, clojure, :outcome_mismatch)

  defp classify_divergence(case_data, div_id, ptc, clojure) do
    case {Map.fetch(case_data, :ptc_expected), ptc} do
      {{:ok, {:error, expected_reason}}, {:error, actual}} ->
        if expected_error?(actual, expected_reason) do
          {:pass, details(case_data, ptc, clojure, div_id: div_id)}
        else
          fail(case_data, ptc, clojure, {:unexpected_divergence_error, div_id})
        end

      {{:ok, expected}, {:ok, actual}} ->
        if normalize(expected) == normalize(actual) do
          {:pass, details(case_data, ptc, clojure, div_id: div_id)}
        else
          fail(case_data, ptc, clojure, {:unexpected_divergence_value, div_id})
        end

      {:error, {:ok, _actual}} ->
        {:pass, details(case_data, ptc, clojure, div_id: div_id)}

      _ ->
        fail(case_data, ptc, clojure, {:unexpected_divergence_outcome, div_id})
    end
  end

  defp expected_error?(_actual, :any), do: true
  defp expected_error?(%{reason: reason}, reason), do: true
  defp expected_error?(_actual, _expected_reason), do: false

  defp classify_ptc_extension(case_data, ptc) do
    case {Map.fetch(case_data, :ptc_expected), ptc} do
      {{:ok, expected}, {:ok, actual}} ->
        if normalize(expected) == normalize(actual) do
          {:pass, details(case_data, ptc, :not_applicable)}
        else
          fail(case_data, ptc, :not_applicable, :ptc_extension_mismatch)
        end

      {:error, {:ok, _actual}} ->
        {:pass, details(case_data, ptc, :not_applicable)}

      _ ->
        fail(case_data, ptc, :not_applicable, :ptc_extension_error)
    end
  end

  defp classify_known_bug(case_data, gap_id, ptc, clojure) do
    case classify_match(case_data, ptc, clojure) do
      {:pass, _details} -> fail(case_data, ptc, clojure, {:bug_no_longer_reproduces, gap_id})
      {:fail, details} -> {:pass, Map.merge(details, %{classification: :bug, gap_id: gap_id})}
    end
  end

  defp classify_unknown(case_data, ptc, clojure) do
    case classify_match(case_data, ptc, clojure) do
      {:pass, details} -> {:pass, Map.put(details, :classification, :match)}
      {:fail, details} -> {:fail, Map.put(details, :classification, :unknown)}
    end
  end

  defp details(case_data, ptc, clojure, extra \\ []) do
    extra
    |> Map.new()
    |> Map.merge(%{
      id: case_data.id,
      namespace: Map.get(case_data, :namespace),
      vars: Map.get(case_data, :vars, []),
      form: case_data.form,
      policy: case_data.policy,
      ptc: ptc,
      clojure: clojure
    })
  end

  defp fail(case_data, ptc, clojure, reason) do
    {:fail, Map.put(details(case_data, ptc, clojure), :reason, reason)}
  end
end
