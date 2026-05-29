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
  @result_marker "__PTC_CLOJURE_RESULT__ "

  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.SourceAtoms

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
          {:ok, output} -> output |> extract_result_output() |> parse_edn_output()
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
  - PTC-specific aggregator/tool stubs (`sum-by`, `avg-by`, `min-by`, `max-by`,
    `pmap`, `pcalls`, `call`, …)
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

      ;; User program. Print a marker after execution so user stdout from
      ;; expressions like println is not mistaken for the return value.
      (let [ptc-result (do #{source})]
        (println "#{@result_marker}" (pr-str ptc-result))))
    """
  end

  # Private functions

  defp run_bb(bb_path, source, timeout \\ @default_timeout) do
    task =
      Task.async(fn ->
        System.cmd(bb_path, ["-e", source],
          stderr_to_stdout: true,
          env: [{"BABASHKA_DISABLE_WARNINGS", "true"}]
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, String.trim(output)}

      {:ok, {output, _exit_code}} ->
        {:error, String.trim(output)}

      nil ->
        {:error, "Babashka execution timed out after #{timeout}ms"}
    end
  end

  defp extract_result_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(output, fn line ->
      case String.split(line, @result_marker, parts: 2) do
        ["", result] -> String.trim(result)
        _ -> nil
      end
    end)
  end

  defp parse_edn_output(output) when output == "" do
    {:ok, nil}
  end

  defp parse_edn_output(output) do
    parse_edn_via_json(output)
  end

  # Parse EDN by converting through JSON
  defp parse_edn_via_json(output) do
    case bb_path() do
      nil ->
        {:error, "Babashka not available"}

      bb ->
        # Use read-string to safely parse EDN (handles lists like (1 2 3)).
        # Encode EDN-specific structures before JSON conversion so sets,
        # keywords, and non-string map keys survive round-tripping.
        escaped = output |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

        json_convert = """
        (require '[cheshire.core :as json])
        (declare ptc-encode)
        (defn ptc-encode-map-entry [[k v]]
          [(ptc-encode k) (ptc-encode v)])
        (defn ptc-encode [x]
          (cond
            (keyword? x) (subs (str x) 1)
            (set? x) {:__ptc_edn_type "set" :items (mapv ptc-encode x)}
            (map? x) {:__ptc_edn_type "map" :entries (mapv ptc-encode-map-entry x)}
            (sequential? x) (mapv ptc-encode x)
            (var? x) {:__ptc_edn_type "var" :name (str x)}
            :else x))
        (println (json/generate-string (ptc-encode (read-string "#{escaped}"))))
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
        str |> String.slice(1..-1//1) |> keyword_value()

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

  # Normalize JSON values (convert tagged EDN structures back to Elixir terms)
  defp normalize_from_json(%{"__ptc_edn_type" => "set", "items" => items}) do
    items
    |> Enum.map(&normalize_from_json/1)
    |> MapSet.new()
  end

  defp normalize_from_json(%{"__ptc_edn_type" => "map", "entries" => entries}) do
    Map.new(entries, fn [key, value] -> {normalize_from_json(key), normalize_from_json(value)} end)
  end

  defp normalize_from_json(%{"__ptc_edn_type" => "var", "name" => name}) do
    ["var", name]
  end

  defp normalize_from_json(value) when is_map(value) do
    Map.new(value, fn {k, v} ->
      key =
        if is_binary(k) and String.starts_with?(k, ":") do
          k |> String.slice(1..-1//1) |> keyword_value()
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

  defp normalize_value(%PtcRunner.Lisp.Format.Var{name: name}) do
    "#'#{name}"
  end

  defp normalize_value(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} ->
      # Convert atom and integer keys to strings for comparison (JSON uses string keys)
      key =
        cond do
          is_atom(k) -> Atom.to_string(k)
          is_integer(k) -> Integer.to_string(k)
          true -> k
        end

      {key, normalize_value(v)}
    end)
  end

  defp normalize_value(["var", name]) when is_binary(name) do
    # Clojure Vars are represented as ["var", "ns/name"] in Cheshire JSON
    short_name = name |> String.split("/") |> List.last()
    "#'#{short_name}"
  end

  defp normalize_value(value) when is_list(value) do
    Enum.map(value, &normalize_value/1)
  end

  defp normalize_value(value)
       when is_atom(value) and not is_boolean(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp normalize_value(%LispKeyword{name: name}), do: name

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

  defp to_edn(%LispKeyword{name: name}), do: ":" <> name

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

  defp keyword_value(name) when is_binary(name) do
    case SourceAtoms.intern(name) do
      atom when is_atom(atom) -> atom
      binary when is_binary(binary) -> LispKeyword.new(binary)
    end
  end

  # PTC-specific function stubs for Clojure
  defp ptc_stubs do
    ~S"""
    ;; Import clojure.walk functions (walk, prewalk, postwalk)
    (require '[clojure.walk :refer [walk prewalk postwalk]])

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

    ;; Parallel execution stubs (run sequentially in BB/Clojure for validation)
    (defn pmap [f & colls] (apply map f colls))
    (defn pcalls [& fns] (mapv #(%) fns))

    ;; Tool call stub (returns nil by default)
    (defn call [tool-name args]
      nil)
    """
  end
end
