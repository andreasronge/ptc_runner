defmodule Mix.Tasks.Ptc.Smoke do
  @shortdoc "Run smoke tests comparing PTC-Lisp with Babashka/Clojure"
  @moduledoc """
  Runs .clj files through both PTC-Lisp and Babashka/Clojure, comparing results.

  ## Usage

      mix ptc.smoke              # Run all smoke tests (using Babashka)
      mix ptc.smoke --clj        # Use Clojure CLI instead of Babashka
      mix ptc.smoke --verbose    # Show detailed output

  ## Test Files

  Place `.clj` files in `test/smoke/`. Each file should be valid in both
  PTC-Lisp and Clojure/Babashka (avoid PTC-specific features like `memory/`,
  `ctx/`, `call`).

  ## Output Normalization

  Results are normalized before comparison to handle expected differences:
  - Map key ordering (PTC-Lisp sorts alphabetically)
  - Vectors vs lists (both treated as sequences)
  - Boolean map keys (`:true`/`:false` vs `true`/`false`)

  ## Exit Codes

  - 0: All tests passed
  - 1: Some tests failed
  - 2: Setup error (Babashka/Clojure not found, etc.)
  """

  use Mix.Task

  alias PtcRunner.Lisp.ClojureValidator

  @smoke_dir "test/smoke"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    verbose = "--verbose" in args
    use_clj = "--clj" in args

    runner = if use_clj, do: :clj, else: :bb

    case check_runner(runner) do
      :ok ->
        :ok

      {:error, msg} ->
        Mix.shell().error(msg)
        System.halt(2)
    end

    case list_smoke_files() do
      [] ->
        Mix.shell().info("No smoke test files found in #{@smoke_dir}/")
        System.halt(2)

      files ->
        run_smoke_tests(files, verbose, runner)
    end
  end

  defp check_runner(:bb) do
    if ClojureValidator.available?() do
      :ok
    else
      {:error, "Babashka not found. Run: mix ptc.install_babashka"}
    end
  end

  defp check_runner(:clj) do
    if System.find_executable("clj") do
      :ok
    else
      {:error,
       "Clojure CLI (clj) not found. Install from https://clojure.org/guides/install_clojure"}
    end
  end

  defp list_smoke_files do
    Path.wildcard(Path.join(@smoke_dir, "*.clj"))
    |> Enum.sort()
  end

  defp run_smoke_tests(files, verbose, runner) do
    runner_name = if runner == :clj, do: "Clojure", else: "Babashka"

    Mix.shell().info("")
    Mix.shell().info("=== PTC-Lisp Smoke Tests (vs #{runner_name}) ===")
    Mix.shell().info("")

    results =
      Enum.map(files, fn file ->
        run_single_test(file, verbose, runner)
      end)

    passed = Enum.count(results, &(&1 == :pass))
    failed = Enum.count(results, &(&1 == :fail))

    Mix.shell().info("")
    Mix.shell().info("Results: #{passed} passed, #{failed} failed")

    if failed > 0 do
      System.halt(1)
    end
  end

  defp run_single_test(file, verbose, runner) do
    basename = Path.basename(file)
    source = File.read!(file)

    ptc_result = run_ptc(source)
    clj_result = run_clojure(source, runner)

    runner_label = if runner == :clj, do: "CLJ", else: "BB"

    case {ptc_result, clj_result} do
      {{:ok, ptc_val}, {:ok, clj_val}} ->
        if values_equal?(ptc_val, clj_val) do
          Mix.shell().info("✓ #{basename}")

          if verbose do
            Mix.shell().info("  PTC: #{inspect(ptc_val)}")
          end

          :pass
        else
          Mix.shell().error("✗ #{basename}")
          Mix.shell().error("  PTC: #{inspect(ptc_val)}")
          Mix.shell().error("  #{runner_label}:  #{inspect(clj_val)}")
          :fail
        end

      {{:error, ptc_err}, {:ok, _}} ->
        Mix.shell().error("✗ #{basename}")
        Mix.shell().error("  PTC error: #{ptc_err}")
        :fail

      {{:ok, _}, {:error, clj_err}} ->
        Mix.shell().error("✗ #{basename}")
        Mix.shell().error("  #{runner_label} error: #{clj_err}")
        :fail

      {{:error, ptc_err}, {:error, clj_err}} ->
        Mix.shell().error("✗ #{basename}")
        Mix.shell().error("  PTC error: #{ptc_err}")
        Mix.shell().error("  #{runner_label} error: #{clj_err}")
        :fail
    end
  end

  defp run_ptc(source) do
    case PtcRunner.Lisp.run(source) do
      {:ok, step} -> {:ok, step.return}
      {:error, step} -> {:error, step.fail.message}
    end
  end

  defp run_clojure(source, :bb) do
    ClojureValidator.execute(source)
  end

  defp run_clojure(source, :clj) do
    run_clj(source)
  end

  # Run source using Clojure CLI
  defp run_clj(source) do
    wrapped = ClojureValidator.wrap_with_stubs(source)

    # Use clj -M -e to evaluate the expression
    case System.cmd("clj", ["-M", "-e", wrapped], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> strip_clj_warnings()
        |> parse_clj_output()

      {output, _exit_code} ->
        {:error, String.trim(output)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Strip Clojure warning lines from output
  defp strip_clj_warnings(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "WARNING:"))
    |> Enum.join("\n")
    |> String.trim()
  end

  # Parse Clojure output (EDN format)
  defp parse_clj_output(""), do: {:ok, nil}
  defp parse_clj_output("nil"), do: {:ok, nil}
  defp parse_clj_output("true"), do: {:ok, true}
  defp parse_clj_output("false"), do: {:ok, false}

  defp parse_clj_output(output) do
    # For complex output, use bb to convert EDN to JSON for parsing
    case ClojureValidator.bb_path() do
      nil ->
        # Fallback: try simple parsing
        {:ok, output}

      bb ->
        escaped = output |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

        json_convert = """
        (require '[cheshire.core :as json])
        (println (json/generate-string (read-string "#{escaped}")))
        """

        case System.cmd(bb, ["-e", json_convert], stderr_to_stdout: true) do
          {json_output, 0} ->
            case Jason.decode(String.trim(json_output)) do
              {:ok, value} -> {:ok, value}
              {:error, _} -> {:ok, output}
            end

          {_, _} ->
            {:ok, output}
        end
    end
  end

  # Compare values with normalization for expected differences
  defp values_equal?(ptc, bb) do
    normalize(ptc) == normalize(bb)
  end

  # Normalize values for comparison
  # Handles: key ordering, atom vs string keys, boolean keys
  defp normalize(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {normalize_key(k), normalize(v)} end)
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Map.new()
  end

  defp normalize(list) when is_list(list) do
    Enum.map(list, &normalize/1)
  end

  defp normalize(other), do: other

  # Normalize map keys to strings for comparison
  # PTC-Lisp returns atoms (:foo), BB via JSON returns strings ("foo")
  defp normalize_key(true), do: "true"
  defp normalize_key(false), do: "false"
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)
end
