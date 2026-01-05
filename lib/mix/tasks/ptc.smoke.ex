defmodule Mix.Tasks.Ptc.Smoke do
  @shortdoc "Run smoke tests comparing PTC-Lisp with Babashka"
  @moduledoc """
  Runs .clj files through both PTC-Lisp and Babashka, comparing results.

  ## Usage

      mix ptc.smoke              # Run all smoke tests
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
  - 2: Setup error (Babashka not found, etc.)
  """

  use Mix.Task

  alias PtcRunner.Lisp.ClojureValidator

  @smoke_dir "test/smoke"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    verbose = "--verbose" in args

    unless ClojureValidator.available?() do
      Mix.shell().error("Babashka not found. Run: mix ptc.install_babashka")
      System.halt(2)
    end

    case list_smoke_files() do
      [] ->
        Mix.shell().info("No smoke test files found in #{@smoke_dir}/")
        System.halt(2)

      files ->
        run_smoke_tests(files, verbose)
    end
  end

  defp list_smoke_files do
    Path.wildcard(Path.join(@smoke_dir, "*.clj"))
    |> Enum.sort()
  end

  defp run_smoke_tests(files, verbose) do
    Mix.shell().info("")
    Mix.shell().info("=== PTC-Lisp Smoke Tests ===")
    Mix.shell().info("")

    results =
      Enum.map(files, fn file ->
        run_single_test(file, verbose)
      end)

    passed = Enum.count(results, &(&1 == :pass))
    failed = Enum.count(results, &(&1 == :fail))

    Mix.shell().info("")
    Mix.shell().info("Results: #{passed} passed, #{failed} failed")

    if failed > 0 do
      System.halt(1)
    end
  end

  defp run_single_test(file, verbose) do
    basename = Path.basename(file)
    source = File.read!(file)

    ptc_result = run_ptc(source)
    bb_result = run_babashka(source)

    case {ptc_result, bb_result} do
      {{:ok, ptc_val}, {:ok, bb_val}} ->
        if values_equal?(ptc_val, bb_val) do
          Mix.shell().info("✓ #{basename}")

          if verbose do
            Mix.shell().info("  PTC: #{inspect(ptc_val)}")
          end

          :pass
        else
          Mix.shell().error("✗ #{basename}")
          Mix.shell().error("  PTC: #{inspect(ptc_val)}")
          Mix.shell().error("  BB:  #{inspect(bb_val)}")
          :fail
        end

      {{:error, ptc_err}, {:ok, _}} ->
        Mix.shell().error("✗ #{basename}")
        Mix.shell().error("  PTC error: #{ptc_err}")
        :fail

      {{:ok, _}, {:error, bb_err}} ->
        Mix.shell().error("✗ #{basename}")
        Mix.shell().error("  BB error: #{bb_err}")
        :fail

      {{:error, ptc_err}, {:error, bb_err}} ->
        Mix.shell().error("✗ #{basename}")
        Mix.shell().error("  PTC error: #{ptc_err}")
        Mix.shell().error("  BB error: #{bb_err}")
        :fail
    end
  end

  defp run_ptc(source) do
    case PtcRunner.Lisp.run(source) do
      {:ok, step} -> {:ok, step.return}
      {:error, step} -> {:error, step.fail.message}
    end
  end

  defp run_babashka(source) do
    ClojureValidator.execute(source)
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
