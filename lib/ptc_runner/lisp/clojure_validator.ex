defmodule PtcRunner.Lisp.ClojureValidator do
  @moduledoc """
  Validates PTC-Lisp programs against Babashka/Clojure.

  Provides validation to ensure:
  1. PTC-Lisp programs are valid Clojure syntax
  2. Runtime functions behave identically to Clojure equivalents

  ## Usage

      # Check if Babashka is available
      PtcRunner.Lisp.ClojureValidator.available?()

      # Validate syntax only (fast)
      PtcRunner.Lisp.ClojureValidator.validate_syntax("(+ 1 2)")

      # Execute and get result
      PtcRunner.Lisp.ClojureValidator.execute("(+ 1 2)")

  ## Installation

  Install Babashka with: `mix ptc.install_babashka`
  """

  @default_timeout 5_000
  @local_bb_path "_build/tools/bb"

  @doc """
  Check if Babashka is available.

  Looks for `bb` at `_build/tools/bb` first, then in system PATH.
  """
  @spec available?() :: boolean()
  def available? do
    bb_path() != nil
  end

  @doc """
  Get the path to the Babashka binary.

  Returns `nil` if not found.
  """
  @spec bb_path() :: String.t() | nil
  def bb_path do
    # Try absolute path first (for when running from project root)
    local_abs_path = Path.expand(@local_bb_path)

    cond do
      File.exists?(local_abs_path) ->
        local_abs_path

      File.exists?(@local_bb_path) ->
        Path.expand(@local_bb_path)

      system_bb = System.find_executable("bb") ->
        system_bb

      true ->
        nil
    end
  end

  @doc """
  Validate that source is valid Clojure syntax.

  Returns `:ok` if valid, `{:error, reason}` if invalid.

  ## Examples

      iex> PtcRunner.Lisp.ClojureValidator.validate_syntax("(+ 1 2)")
      :ok

      iex> PtcRunner.Lisp.ClojureValidator.validate_syntax("(+ 1 2")
      {:error, "Syntax error: ..."}
  """
  @spec validate_syntax(String.t()) :: :ok | {:error, String.t()}
  def validate_syntax(source) do
    case bb_path() do
      nil ->
        {:error, "Babashka not installed. Run: mix ptc.install_babashka"}

      bb ->
        # Use read-string to parse without executing
        # Escape backslashes and quotes for Clojure string literal
        escaped = source |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
        clj_source = "(read-string \"#{escaped}\")"

        case run_bb(bb, clj_source) do
          {:ok, _} -> :ok
          {:error, msg} -> {:error, "Syntax error: #{msg}"}
        end
    end
  end

  @doc """
  Execute source in Babashka and return the result.

  ## Options

    * `:timeout` - Timeout in milliseconds (default: 5000)
    * `:context` - Context map to inject as `ctx` binding
    * `:memory` - Memory map to inject as `memory` binding

  ## Examples

      iex> PtcRunner.Lisp.ClojureValidator.execute("(+ 1 2 3)")
      {:ok, 6}

      iex> PtcRunner.Lisp.ClojureValidator.execute("(filter even? [1 2 3 4])")
      {:ok, [2, 4]}
  """
  @spec execute(String.t(), keyword()) :: {:ok, any()} | {:error, String.t()}
  def execute(source, opts \\ []) do
    case bb_path() do
      nil ->
        {:error, "Babashka not installed. Run: mix ptc.install_babashka"}

      bb ->
        context = Keyword.get(opts, :context, %{})
        memory = Keyword.get(opts, :memory, %{})
        timeout = Keyword.get(opts, :timeout, @default_timeout)

        wrapped = wrap_with_stubs(source, context, memory)

        case run_bb(bb, wrapped, timeout) do
          {:ok, output} -> parse_edn_output(output)
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Compare a PTC-Lisp result with a Clojure result.

  Handles normalization of types that differ between systems:
  - Elixir atoms vs Clojure keywords
  - Map key type differences

  Returns `:match` if equivalent, `{:mismatch, details}` otherwise.
  """
  @spec compare_results(any(), any()) :: :match | {:mismatch, String.t()}
  def compare_results(ptc_result, clj_result) do
    normalized_ptc = normalize_value(ptc_result)
    normalized_clj = normalize_value(clj_result)

    if normalized_ptc == normalized_clj do
      :match
    else
      {:mismatch,
       "PTC-Lisp returned #{inspect(ptc_result)}, Clojure returned #{inspect(clj_result)}"}
    end
  end

  @doc """
  Wrap PTC-Lisp source with Clojure stubs for PTC-specific features.

  Adds definitions for:
  - `ctx` - Context data as a map
  - `memory` - Memory data as a map
  - PTC-specific functions: `where`, `all-of`, `any-of`, `none-of`, etc.
  """
  @spec wrap_with_stubs(String.t(), map(), map()) :: String.t()
  def wrap_with_stubs(source, context \\ %{}, memory \\ %{}) do
    ctx_edn = to_edn(context)
    mem_edn = to_edn(memory)

    """
    (do
      ;; Context and memory bindings
      (def ctx #{ctx_edn})
      (def memory #{mem_edn})

      #{ptc_stubs()}

      ;; User program
      #{source})
    """
  end

  # Private functions

  defp run_bb(bb_path, source, timeout \\ @default_timeout) do
    case System.cmd(bb_path, ["-e", source],
           stderr_to_stdout: true,
           env: [{"BABASHKA_DISABLE_WARNINGS", "true"}]
         ) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, _exit_code} ->
        {:error, String.trim(output)}
    end
  catch
    :exit, {:timeout, _} ->
      {:error, "Babashka execution timed out after #{timeout}ms"}
  end

  defp parse_edn_output(output) when output == "" do
    {:ok, nil}
  end

  defp parse_edn_output(output) do
    # Special handling for sets to preserve type
    if String.match?(output, ~r/^\#\{.*\}$/s) do
      parse_edn_set(output)
    else
      parse_edn_via_json(output)
    end
  end

  # Parse EDN by converting through JSON
  defp parse_edn_via_json(output) do
    case bb_path() do
      nil ->
        {:error, "Babashka not available"}

      bb ->
        # Use read-string to safely parse EDN (handles lists like (1 2 3))
        # Then convert to JSON. The read-string prevents (1 2 3) being interpreted
        # as a function call.
        escaped = output |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

        json_convert = """
        (require '[cheshire.core :as json])
        (println (json/generate-string (read-string "#{escaped}")))
        """

        case run_bb(bb, json_convert) do
          {:ok, json_output} ->
            case Jason.decode(json_output) do
              {:ok, value} -> {:ok, normalize_from_json(value)}
              {:error, _} -> {:ok, parse_simple_edn(output)}
            end

          {:error, _} ->
            # Fallback to simple parsing
            {:ok, parse_simple_edn(output)}
        end
    end
  end

  # Parse Clojure set notation #{...} and return as MapSet
  defp parse_edn_set(output) do
    # Extract content between #{ and }
    case Regex.run(~r/^\#\{(.*)\}$/s, output, capture: :all_but_first) do
      [content] ->
        # Split by whitespace and parse each element
        elements =
          content
          |> String.trim()
          |> String.split(~r/\s+/, trim: true)
          |> Enum.map(&parse_simple_edn/1)

        {:ok, MapSet.new(elements)}

      _ ->
        # Fallback: parse as simple EDN
        {:ok, parse_simple_edn(output)}
    end
  end

  # Simple EDN parser for basic types
  defp parse_simple_edn("nil"), do: nil
  defp parse_simple_edn("true"), do: true
  defp parse_simple_edn("false"), do: false

  defp parse_simple_edn(str) do
    cond do
      # Integer
      Regex.match?(~r/^-?\d+$/, str) ->
        String.to_integer(str)

      # Float
      Regex.match?(~r/^-?\d+\.\d+$/, str) ->
        String.to_float(str)

      # Keyword
      String.starts_with?(str, ":") ->
        str |> String.slice(1..-1//1) |> String.to_atom()

      # String (quoted)
      String.starts_with?(str, "\"") and String.ends_with?(str, "\"") ->
        str |> String.slice(1..-2//1)

      # Vector - parse as list
      String.starts_with?(str, "[") and String.ends_with?(str, "]") ->
        parse_edn_collection(str)

      # List (Clojure lazy seq) - parse as list
      String.starts_with?(str, "(") and String.ends_with?(str, ")") ->
        parse_edn_collection(str)

      # Map
      String.starts_with?(str, "{") and String.ends_with?(str, "}") ->
        parse_edn_collection(str)

      # Default: return as string
      true ->
        str
    end
  end

  defp parse_edn_collection(str) do
    # For complex structures, use bb to convert to JSON
    case bb_path() do
      nil ->
        str

      bb ->
        # Convert lists to vectors for JSON serialization
        # (1 2 3) -> [1 2 3] since JSON doesn't support Clojure lists
        json_convert = """
        (require '[cheshire.core :as json])
        (println (json/generate-string (vec #{str})))
        """

        case run_bb(bb, json_convert) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, value} -> normalize_from_json(value)
              {:error, _} -> str
            end

          {:error, _} ->
            str
        end
    end
  end

  # Normalize JSON values (convert string keys back to atoms for keywords)
  defp normalize_from_json(value) when is_map(value) do
    Map.new(value, fn {k, v} ->
      key =
        if is_binary(k) and String.starts_with?(k, ":") do
          k |> String.slice(1..-1//1) |> String.to_atom()
        else
          k
        end

      {key, normalize_from_json(v)}
    end)
  end

  defp normalize_from_json(value) when is_list(value) do
    Enum.map(value, &normalize_from_json/1)
  end

  defp normalize_from_json(value), do: value

  # Normalize values for comparison
  defp normalize_value(%MapSet{} = set) do
    set |> MapSet.to_list() |> Enum.sort() |> Enum.map(&normalize_value/1)
  end

  defp normalize_value(value) when is_map(value) do
    Map.new(value, fn {k, v} ->
      # Convert atom keys to strings for comparison
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, normalize_value(v)}
    end)
  end

  defp normalize_value(value) when is_list(value) do
    Enum.map(value, &normalize_value/1)
  end

  defp normalize_value(value)
       when is_atom(value) and not is_boolean(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp normalize_value(value), do: value

  # Convert Elixir value to EDN string
  defp to_edn(nil), do: "nil"
  defp to_edn(true), do: "true"
  defp to_edn(false), do: "false"
  defp to_edn(n) when is_integer(n), do: Integer.to_string(n)
  defp to_edn(n) when is_float(n), do: Float.to_string(n)
  defp to_edn(s) when is_binary(s), do: inspect(s)

  defp to_edn(a) when is_atom(a) do
    ":" <> Atom.to_string(a)
  end

  defp to_edn(list) when is_list(list) do
    items = Enum.map_join(list, " ", &to_edn/1)
    "[#{items}]"
  end

  defp to_edn(%MapSet{} = set) do
    items = set |> MapSet.to_list() |> Enum.map_join(" ", &to_edn/1)
    "\#{#{items}}"
  end

  defp to_edn(map) when is_map(map) do
    items =
      Enum.map_join(map, " ", fn {k, v} ->
        "#{to_edn(k)} #{to_edn(v)}"
      end)

    "{#{items}}"
  end

  # PTC-specific function stubs for Clojure
  defp ptc_stubs do
    ~S"""
    ;; Helper to coerce keyword to string for comparison (PTC-Lisp behavior)
    (defn- coerce-for-compare [v]
      (if (keyword? v) (name v) v))

    ;; Helper to get value from item, supporting both keywords and paths
    (defn- flex-get [item field]
      (if (vector? field)
        (get-in item field)
        (get item field)))

    ;; PTC-specific predicate builders
    ;; where must be a macro because PTC-Lisp treats the operator as a symbol
    (defmacro where
      ([field] `(fn [item#] (boolean (flex-get item# ~field))))
      ([field op value]
       (case op
         = `(fn [item#]
              (let [v# (flex-get item# ~field)
                    cmp# (coerce-for-compare ~value)]
                (or (= v# ~value) (= v# cmp#))))
         not= `(fn [item#]
                 (let [v# (flex-get item# ~field)
                       cmp# (coerce-for-compare ~value)]
                   (and (not= v# ~value) (not= v# cmp#))))
         > `(fn [item#] (> (flex-get item# ~field) ~value))
         < `(fn [item#] (< (flex-get item# ~field) ~value))
         >= `(fn [item#] (>= (flex-get item# ~field) ~value))
         <= `(fn [item#] (<= (flex-get item# ~field) ~value))
         includes `(fn [item#]
                     (let [v# (flex-get item# ~field)
                           cmp# (coerce-for-compare ~value)]
                       (cond
                         (string? v#) (.contains v# (str cmp#))
                         (sequential? v#) (some #(or (= % ~value) (= % cmp#)) v#)
                         :else false)))
         in `(fn [item#]
               (let [v# (flex-get item# ~field)
                     coll# (map coerce-for-compare ~value)]
                 (or (contains? (set ~value) v#)
                     (contains? (set coll#) v#)))))))

    (defn all-of [& preds]
      (fn [item] (every? #(% item) preds)))

    (defn any-of [& preds]
      (fn [item] (some #(% item) preds)))

    (defn none-of [& preds]
      (fn [item] (not-any? #(% item) preds)))

    ;; PTC-specific aggregators
    (defn sum-by [key coll]
      (reduce + 0 (map #(or (get % key) 0) coll)))

    (defn avg-by [key coll]
      (let [vals (remove nil? (map #(get % key) coll))]
        (when (seq vals)
          (double (/ (reduce + vals) (count vals))))))

    (defn min-by [key coll]
      (when (seq coll)
        (let [valid (filter #(some? (get % key)) coll)]
          (when (seq valid)
            (apply min-key #(get % key) valid)))))

    (defn max-by [key coll]
      (when (seq coll)
        (let [valid (filter #(some? (get % key)) coll)]
          (when (seq valid)
            (apply max-key #(get % key) valid)))))

    ;; PTC-specific collection functions
    (defn pluck [key coll]
      (map #(get % key) coll))

    ;; Tool call stub (returns nil by default)
    (defn call [tool-name args]
      nil)
    """
  end
end
