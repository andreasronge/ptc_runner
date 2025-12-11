defmodule PtcRunner.TestSupport.ClojureTestHelpers do
  @moduledoc """
  Test helpers for Clojure validation.

  Provides assertions and utilities for comparing PTC-Lisp behavior
  against real Clojure (via Babashka).

  ## Usage in Tests

      defmodule MyTest do
        use ExUnit.Case
        import PtcRunner.TestSupport.ClojureTestHelpers

        describe "Clojure conformance" do
          @describetag :clojure

          setup do
            require_babashka()
            :ok
          end

          test "addition matches Clojure" do
            assert_clojure_equivalent("(+ 1 2 3)")
          end
        end
      end
  """

  alias PtcRunner.Lisp.ClojureValidator

  @doc """
  Check if Babashka is available for Clojure validation.

  Returns `:ok` if Babashka is installed, `{:skip, message}` otherwise.

  Note: Clojure tests are excluded in CI via `--exclude clojure` flag.
  For local development, install Babashka with `mix ptc.install_babashka`.
  """
  @spec require_babashka() :: :ok | {:skip, String.t()}
  def require_babashka do
    if ClojureValidator.available?() do
      :ok
    else
      {:skip, "Babashka not installed. Run: mix ptc.install_babashka"}
    end
  end

  @doc """
  Assert that a PTC-Lisp expression produces the same result in Clojure.

  Runs the expression through both PTC-Lisp and Babashka, then compares results.

  ## Options

    * `:context` - Context map for PTC-Lisp execution
    * `:memory` - Memory map for PTC-Lisp execution

  ## Example

      assert_clojure_equivalent("(filter even? [1 2 3 4])")
      assert_clojure_equivalent("(get ctx :name)", context: %{name: "Alice"})
  """
  @spec assert_clojure_equivalent(String.t(), keyword()) :: :ok | no_return()
  def assert_clojure_equivalent(source, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    memory = Keyword.get(opts, :memory, %{})

    # Run in PTC-Lisp
    ptc_result =
      case PtcRunner.Lisp.run(source, context: context, memory: memory) do
        {:ok, result, _delta, _memory} -> {:ok, result}
        {:error, _} = err -> err
      end

    # Run in Babashka
    clj_result = ClojureValidator.execute(source, context: context, memory: memory)

    # Compare results
    case {ptc_result, clj_result} do
      {{:ok, ptc_val}, {:ok, clj_val}} ->
        case ClojureValidator.compare_results(ptc_val, clj_val) do
          :match ->
            :ok

          {:mismatch, msg} ->
            flunk("""
            Clojure conformance failure for: #{source}

            #{msg}
            """)
        end

      {{:error, ptc_err}, {:ok, clj_val}} ->
        flunk("""
        PTC-Lisp error but Clojure succeeded for: #{source}

        PTC-Lisp error: #{inspect(ptc_err)}
        Clojure result: #{inspect(clj_val)}
        """)

      {{:ok, ptc_val}, {:error, clj_err}} ->
        flunk("""
        PTC-Lisp succeeded but Clojure error for: #{source}

        PTC-Lisp result: #{inspect(ptc_val)}
        Clojure error: #{clj_err}
        """)

      {{:error, _ptc_err}, {:error, _clj_err}} ->
        # Both errored - that's acceptable (consistent behavior)
        :ok
    end
  end

  @doc """
  Assert that source is valid Clojure syntax.

  Only validates syntax, does not execute the code.

  ## Example

      assert_valid_clojure_syntax("(->> [1 2 3] (map inc) (filter even?))")
  """
  @spec assert_valid_clojure_syntax(String.t()) :: :ok | no_return()
  def assert_valid_clojure_syntax(source) do
    case ClojureValidator.validate_syntax(source) do
      :ok ->
        :ok

      {:error, msg} ->
        flunk("""
        Invalid Clojure syntax: #{source}

        Error: #{msg}
        """)
    end
  end

  @doc """
  Assert that source produces a specific result in both PTC-Lisp and Clojure.

  Useful when you want to verify both the PTC-Lisp result AND Clojure conformance.

  ## Example

      assert_both_return("(+ 1 2)", 3)
      assert_both_return("(count [1 2 3])", 3)
  """
  @spec assert_both_return(String.t(), any(), keyword()) :: :ok | no_return()
  def assert_both_return(source, expected, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    memory = Keyword.get(opts, :memory, %{})

    # Check PTC-Lisp
    case PtcRunner.Lisp.run(source, context: context, memory: memory) do
      {:ok, result, _delta, _memory} ->
        assert result == expected,
               "PTC-Lisp: expected #{inspect(expected)}, got #{inspect(result)}"

      {:error, err} ->
        flunk("PTC-Lisp error: #{inspect(err)}")
    end

    # Check Clojure
    case ClojureValidator.execute(source, context: context, memory: memory) do
      {:ok, result} ->
        # Normalize for comparison
        normalized_expected = normalize_for_clojure(expected)
        normalized_result = normalize_for_clojure(result)

        assert normalized_result == normalized_expected,
               "Clojure: expected #{inspect(expected)}, got #{inspect(result)}"

      {:error, err} ->
        flunk("Clojure error: #{err}")
    end

    :ok
  end

  # Normalize values for Clojure comparison (atoms become strings, etc.)
  defp normalize_for_clojure(value) when is_map(value) do
    Map.new(value, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, normalize_for_clojure(v)}
    end)
  end

  defp normalize_for_clojure(value) when is_list(value) do
    Enum.map(value, &normalize_for_clojure/1)
  end

  defp normalize_for_clojure(value)
       when is_atom(value) and not is_boolean(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp normalize_for_clojure(value), do: value

  # Import ExUnit assertions
  defp flunk(message) do
    ExUnit.Assertions.flunk(message)
  end

  defp assert(condition, message) do
    ExUnit.Assertions.assert(condition, message)
  end
end
