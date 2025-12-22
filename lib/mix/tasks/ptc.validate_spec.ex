defmodule Mix.Tasks.Ptc.ValidateSpec do
  @moduledoc """
  Validates PTC-Lisp specification against implementation.

  Extracts examples from the specification and runs them through the PTC-Lisp
  interpreter to detect drift between specification and implementation.

  ## Usage

      mix ptc.validate_spec
      mix ptc.validate_spec --clojure

  ## Options

    * `--clojure` - Compare results with Babashka/Clojure (requires Babashka installed)

  ## Output

  Displays:
  - Examples grouped by specification section
  - Validation results (passed/failed)
  - Warnings for section hash mismatches
  - Optional Clojure comparison results

  ## Exit Codes

  - 0: All examples passed
  - 1: Some examples failed
  - 2: Could not load or validate specification
  """

  use Mix.Task

  @shortdoc "Validate PTC-Lisp specification against implementation"

  alias PtcRunner.Lisp.{ClojureValidator, SpecValidator}

  @checksums_path "test/spec_cases/checksums.exs"

  @impl Mix.Task
  def run(args) do
    use_clojure = "--clojure" in args

    case SpecValidator.validate_spec() do
      {:ok, results} ->
        display_results(results, use_clojure)
        check_section_hashes()
        validate_negative_tests()

        if results.failed == 0 do
          :ok
        else
          System.halt(1)
        end

      {:error, reason} ->
        Mix.shell().error("Error: #{reason}")
        System.halt(2)
    end
  end

  defp display_results(results, use_clojure) do
    total = results.passed + results.failed
    percentage = if total > 0, do: round(results.passed / total * 100), else: 100

    Mix.shell().info("")
    Mix.shell().info("=== PTC-Lisp Specification Validation ===")
    Mix.shell().info("")
    Mix.shell().info("Total examples:  #{total}")
    Mix.shell().info("Passed:          #{results.passed}")
    Mix.shell().info("Failed:          #{results.failed}")
    Mix.shell().info("Success rate:    #{percentage}%")

    # Display section-grouped results
    if map_size(results.by_section) > 0 do
      display_section_results(results.by_section)
    end

    if results.failed > 0 do
      Mix.shell().info("")
      Mix.shell().info("=== Failures ===")
      Mix.shell().info("")

      Enum.each(Enum.reverse(results.failures), fn failure ->
        display_failure(failure)
      end)
    end

    if use_clojure and ClojureValidator.available?() do
      compare_with_clojure(results)
    end

    Mix.shell().info("")
  end

  defp display_section_results(by_section) do
    Mix.shell().info("")
    Mix.shell().info("=== Results by Section ===")
    Mix.shell().info("")

    by_section
    |> Enum.sort()
    |> Enum.each(fn {section, stats} ->
      total = stats.passed + stats.failed

      display_section =
        if section do
          section
        else
          "Unlabeled"
        end

      if stats.failed == 0 do
        Mix.shell().info("✓ #{display_section}: #{total} passed")
      else
        Mix.shell().info("✗ #{display_section}: #{stats.passed}/#{total} passed")
      end
    end)
  end

  defp display_failure({code, expected, reason, _section}) do
    Mix.shell().error("Code: #{code}")
    Mix.shell().error("Expected: #{inspect(expected)}")
    Mix.shell().error("Reason: #{reason}")
    Mix.shell().info("")
  end

  defp check_section_hashes do
    case load_stored_checksums() do
      {:ok, stored} ->
        display_hash_mismatches(stored)

      {:error, _reason} ->
        :ok
    end
  end

  defp display_hash_mismatches(stored) do
    case SpecValidator.section_hashes() do
      {:ok, current} ->
        mismatches = find_mismatches(stored, current)

        if map_size(mismatches) > 0 do
          Mix.shell().info("⚠ Section changes detected:")
          Mix.shell().info("")

          Enum.each(mismatches, fn {section, {_stored, _current}} ->
            Mix.shell().info("  - #{section}")
          end)

          Mix.shell().info("")
          Mix.shell().info("Run: mix ptc.update_spec_checksums")
          Mix.shell().info("")
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp validate_negative_tests do
    Mix.shell().info("Validating unsupported features (Section 13)...")
    Mix.shell().info("")

    tests = SpecValidator.negative_tests()
    {passed, failed} = validate_negative_tests(tests, 0, 0)

    Mix.shell().info("Negative tests: #{passed}/#{length(tests)} correctly rejected")
    Mix.shell().info("")

    if failed > 0 do
      Mix.shell().info("⚠ Failed unsupported feature tests: #{failed}")
      Mix.shell().info("")
    end
  end

  defp validate_negative_tests([], passed, failed) do
    {passed, failed}
  end

  defp validate_negative_tests([{_feature, code, expected_error} | rest], passed, failed) do
    case SpecValidator.validate_negative_test(code, expected_error) do
      :ok ->
        validate_negative_tests(rest, passed + 1, failed)

      {:error, _reason} ->
        validate_negative_tests(rest, passed, failed + 1)
    end
  end

  defp compare_with_clojure(_results) do
    Mix.shell().info("")
    Mix.shell().info("=== Clojure Comparison ===")
    Mix.shell().info("")

    case SpecValidator.extract_examples() do
      {:ok, examples} ->
        compare_examples_with_clojure(examples)

      {:error, _reason} ->
        :ok
    end
  end

  defp compare_examples_with_clojure(examples) do
    {matched, mismatched} =
      examples
      |> Enum.filter(&ptc_compatible?/1)
      |> Enum.reduce({0, 0}, fn {code, expected, _section}, acc ->
        validate_code_against_clojure(code, expected, acc)
      end)

    Mix.shell().info("Clojure matched: #{matched}")

    if mismatched > 0 do
      Mix.shell().info("Clojure mismatches: #{mismatched}")
    end
  end

  defp validate_code_against_clojure(code, expected, {m, mm}) do
    case ClojureValidator.execute(code) do
      {:ok, clj_result} ->
        case ClojureValidator.compare_results(expected, clj_result) do
          :match ->
            {m + 1, mm}

          {:mismatch, reason} ->
            Mix.shell().info("Mismatch in: #{code}")
            Mix.shell().info("  #{reason}")
            {m, mm + 1}
        end

      {:error, _reason} ->
        {m, mm}
    end
  end

  defp ptc_compatible?({code, _expected, _section}) do
    # Skip examples with PTC-specific features
    ptc_specific = ["memory/", "ctx/", "where", "all-of", "any-of", "none-of", "call"]
    not Enum.any?(ptc_specific, &String.contains?(code, &1))
  end

  defp load_stored_checksums do
    path = Path.expand(@checksums_path)

    case File.read(path) do
      {:ok, content} ->
        case Code.eval_string(content) do
          {checksums, _} when is_map(checksums) ->
            {:ok, checksums}

          _ ->
            {:error, "Invalid checksums format"}
        end

      {:error, _} ->
        {:error, "Checksums file not found"}
    end
  end

  defp find_mismatches(stored, current) do
    Enum.reduce(stored, %{}, fn {section, stored_hash}, acc ->
      current_hash = Map.get(current, section)

      if current_hash && current_hash != stored_hash do
        Map.put(acc, section, {stored_hash, current_hash})
      else
        acc
      end
    end)
  end
end
