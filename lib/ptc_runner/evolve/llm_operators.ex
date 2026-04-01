defmodule PtcRunner.Evolve.LLMOperators do
  @moduledoc """
  LLM-powered mutation operators for GP evolution.

  Uses decomposed, small-step mutations: the LLM suggests ONE targeted
  change at a time, guided by working PTC-Lisp examples. Each call's
  token cost is tracked for the fitness penalty.
  """

  alias PtcRunner.Evolve.Individual
  alias PtcRunner.LLM

  @ptc_lisp_examples """
  Working PTC-Lisp examples (copy these patterns exactly):

  ;; Filter a list
  (filter (fn [x] (> (get x :price) 500)) data/products)

  ;; Map to extract a field
  (map (fn [x] (get x :name)) data/employees)

  ;; Count items
  (count (filter (fn [x] (= (get x :status) "delivered")) data/orders))

  ;; Sum a field
  (reduce + 0 (map (fn [x] (get x :total)) data/orders))

  ;; Average
  (let [items (filter (fn [x] (> (get x :amount) 100)) data/expenses)
        total (reduce + 0 (map (fn [x] (get x :amount)) items))]
    (/ total (count items)))

  ;; Group-by and count per group
  (let [grouped (group-by (fn [e] (get e :department)) data/employees)]
    (into {} (map (fn [[k v]] [k (count v)]) grouped)))

  ;; Cross-dataset join using set membership
  (let [eng-ids (set (map (fn [e] (get e :id))
                          (filter (fn [e] (= (get e :department) "engineering")) data/employees)))
        eng-expenses (filter (fn [ex] (contains? eng-ids (get ex :employee_id))) data/expenses)]
    (count eng-expenses))

  ;; Group-by, filter groups, then join
  (let [dept-groups (group-by (fn [e] (get e :department)) data/employees)
        big-depts (map first (filter (fn [[dept emps]] (> (count emps) 30)) dept-groups))
        big-dept-set (set big-depts)
        emp-ids (set (map (fn [e] (get e :id))
                          (filter (fn [e] (contains? big-dept-set (get e :department))) data/employees)))
        matching (filter (fn [ex] (contains? emp-ids (get ex :employee_id))) data/expenses)]
    (/ (reduce + 0 (map (fn [ex] (get ex :amount)) matching))
       (count matching)))

  SYNTAX RULES:
  - Use [x] for fn params, NOT (x)
  - Use [k v] for let bindings, NOT (k v)
  - Strings use double quotes: "delivered"
  - Keywords use colon prefix: :price :status :id
  - (set list) creates a set, NOT \#{...}
  - (into {} pairs) converts to map
  - (contains? set-or-map key) for membership test
  - (get map key) or (get map key default) for field access
  """

  @doc """
  Ask the LLM to make ONE small improvement to a program.

  The prompt is decomposed: diagnose the specific issue, suggest one change,
  include working PTC-Lisp examples to copy from.

  Returns `{:ok, individual, tokens_used}` or `{:error, reason}`.
  """
  @spec improve(Individual.t(), term(), term(), atom(), String.t(), String.t()) ::
          {:ok, Individual.t(), non_neg_integer()} | {:error, term()}
  def improve(
        %Individual{source: source, id: parent_id, generation: gen},
        actual_output,
        expected_output,
        output_type,
        model,
        description \\ ""
      ) do
    # Diagnose the gap
    diagnosis = diagnose(actual_output, expected_output, output_type)

    desc_section =
      if description != "" do
        "Problem: #{description}\n\n"
      else
        ""
      end

    prompt = """
    You are improving a PTC-Lisp program. Make ONE small change to fix it.

    #{desc_section}Current program:
    #{source}

    It produced: #{format_output(actual_output)}
    Expected:    #{format_output(expected_output)} (type: #{output_type})

    Diagnosis: #{diagnosis}

    Available data variables:
    - data/products (500 items: id, name, category, price, stock, rating, status)
    - data/orders (1000 items: id, customer_id, product_id, quantity, total, status, payment_method)
    - data/employees (200 items: id, name, department, level, salary, bonus, remote, years_employed)
    - data/expenses (800 items: id, employee_id, category, amount, status, date)

    #{@ptc_lisp_examples}

    Return ONLY the improved PTC-Lisp program. No explanation. No markdown fences.
    """

    request = %{
      system:
        "You write PTC-Lisp programs. Return ONLY valid PTC-Lisp code. " <>
          "Copy syntax exactly from the examples. Use [x] for fn params, not (x).",
      messages: [%{role: :user, content: prompt}]
    }

    case LLM.call(model, request) do
      {:ok, %{content: content} = resp} ->
        new_source = clean_source(content)
        token_count = extract_token_count(Map.get(resp, :tokens, %{}))

        case Individual.from_source(new_source,
               parent_ids: [parent_id],
               generation: gen + 1,
               metadata: %{operator: :llm_improve, llm_tokens: token_count, diagnosis: diagnosis}
             ) do
          {:ok, ind} ->
            {:ok, %{ind | llm_tokens_used: token_count}, token_count}

          {:error, reason} ->
            {:error, {:parse_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:llm_error, reason}}
    end
  end

  # Diagnose the specific gap between actual and expected output
  defp diagnose(nil, _expected, _type),
    do: "Program crashed or returned nil. Start with a simpler approach."

  defp diagnose(actual, expected, :number) when is_number(actual) and is_number(expected) do
    ratio = if expected != 0, do: actual / expected, else: 0

    cond do
      abs(ratio - 1.0) < 0.05 ->
        "Close! The value #{trunc(actual)} is near #{trunc(expected)} but computed over the wrong subset. Add a filter step."

      actual > expected * 1.5 ->
        "Too high (#{trunc(actual)} vs #{trunc(expected)}). You're including too many items. Add a filter to narrow the dataset."

      actual < expected * 0.5 ->
        "Too low (#{trunc(actual)} vs #{trunc(expected)}). You're missing items. Check your filter conditions."

      true ->
        "Wrong value (#{trunc(actual)} vs #{trunc(expected)}). The computation logic needs adjustment."
    end
  end

  defp diagnose(actual, expected, :integer) when is_integer(actual) and is_integer(expected) do
    cond do
      abs(actual - expected) < 10 ->
        "Close! Off by #{abs(actual - expected)}. Tweak the filter threshold."

      actual > expected ->
        "Too high (#{actual} vs #{expected}). Your filter is too broad."

      true ->
        "Too low (#{actual} vs #{expected}). Your filter is too strict."
    end
  end

  defp diagnose(actual, expected, :map) when is_map(actual) and is_map(expected) do
    actual_keys = Map.keys(actual) |> MapSet.new()
    expected_keys = Map.keys(expected) |> MapSet.new()

    cond do
      MapSet.equal?(actual_keys, expected_keys) ->
        "Right keys but wrong values. The grouping is correct, fix the aggregation per group."

      MapSet.size(MapSet.intersection(actual_keys, expected_keys)) > 0 ->
        "Some keys match but not all. Fix the grouping key extraction."

      true ->
        "Wrong keys entirely. You need to group-by the right field. Expected keys: #{inspect(MapSet.to_list(expected_keys))}"
    end
  end

  defp diagnose(actual, _expected, type) do
    actual_type = typeof(actual)

    if actual_type == type do
      "Right type (#{type}) but wrong value. Check the computation logic."
    else
      "Wrong type: got #{actual_type}, expected #{type}. Restructure the program."
    end
  end

  defp typeof(x) when is_integer(x), do: :integer
  defp typeof(x) when is_float(x), do: :number
  defp typeof(x) when is_number(x), do: :number
  defp typeof(x) when is_binary(x), do: :string
  defp typeof(x) when is_list(x), do: :list
  defp typeof(x) when is_map(x), do: :map
  defp typeof(_), do: :unknown

  defp format_output(x) when is_map(x), do: inspect(x, limit: 10)
  defp format_output(x) when is_list(x), do: inspect(x, limit: 10)
  defp format_output(x), do: inspect(x)

  defp clean_source(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```[\w]*\n?/, "")
    |> String.replace(~r/\n?```\s*$/, "")
    |> String.trim()
  end

  defp extract_token_count(%{total_tokens: t}) when is_integer(t), do: t

  defp extract_token_count(%{input_tokens: i, output_tokens: o})
       when is_integer(i) and is_integer(o),
       do: i + o

  defp extract_token_count(%{input: i, output: o}) when is_integer(i) and is_integer(o),
    do: i + o

  defp extract_token_count(_), do: 0
end
