defmodule PtcRunner.Kernel.SelectionRules do
  @moduledoc """
  Sealed, non-executable provider-selection normalization rules.

  Rules contain only bounded data: exact fields, scalar or unique-list types,
  literal or named-set defaults, finite named sets, and the closed cross-rule
  vocabulary `subset_of`, `required_when_set_nonempty`, and
  `ceiling_of_context_limit`. They cannot contain functions, modules, MFAs,
  regular expressions, or caller-owned schemas.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits

  @max_fields 32
  @max_named_sets 32
  @max_set_items 128
  @name ~r/\A[a-z][a-z0-9._-]{0,127}\z/

  @enforce_keys [:fields, :cross_rules, :named_sets]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type scalar_type :: :string | :integer | :boolean | {:unique_list, :string}
  @type default ::
          term()
          | {:named_set, binary()}
          | {:intersection, binary(), binary()}
  @type field :: %{
          required(:type) => scalar_type(),
          required(:input) => boolean(),
          optional(:required) => boolean(),
          optional(:default) => default(),
          optional(:minimum) => integer(),
          optional(:maximum) => integer(),
          optional(:minimum_items) => non_neg_integer(),
          optional(:members) => binary()
        }
  @type cross_rule ::
          {:subset_of, binary(), binary()}
          | {:required_when_set_nonempty, binary(), binary()}
          | {:ceiling_of_context_limit, binary(), atom()}
  @type t :: %__MODULE__{
          fields: %{binary() => field()},
          cross_rules: [cross_rule()],
          named_sets: %{binary() => [binary()]},
          attestation: binary() | nil
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_selection_rules}
  @doc "Validates and seals one closed selection-rule program."
  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Keyword.keys(opts) |> Enum.sort() == [:cross_rules, :fields, :named_sets] do
      rules = %__MODULE__{
        fields: Keyword.fetch!(opts, :fields),
        cross_rules: Keyword.fetch!(opts, :cross_rules),
        named_sets: Keyword.fetch!(opts, :named_sets)
      }

      if valid_shape?(rules) do
        {:ok, %{rules | attestation: Attestation.attest(__MODULE__, payload(rules))}}
      else
        {:error, :invalid_selection_rules}
      end
    else
      {:error, :invalid_selection_rules}
    end
  end

  def new(_opts), do: {:error, :invalid_selection_rules}

  @spec valid?(term()) :: boolean()
  @doc "Checks the complete data-only rule shape and its construction seal."
  def valid?(%__MODULE__{attestation: attestation} = rules),
    do:
      Enum.sort(Map.keys(rules)) == @field_keys and valid_shape?(rules) and
        Attestation.valid?(__MODULE__, payload(rules), attestation)

  def valid?(_rules), do: false

  @spec normalize(t(), term(), Limits.t()) ::
          {:ok, map()} | {:error, :invalid_selection}
  @doc "Purely normalizes one provider selection under the effective limits."
  def normalize(%__MODULE__{} = rules, value, %Limits{} = limits)
      when is_map(value) and not is_struct(value) do
    with true <- valid?(rules),
         true <- Limits.valid?(limits),
         true <- Enum.all?(Map.keys(value), &is_binary/1),
         true <- Map.keys(value) -- input_fields(rules) == [],
         :ok <- required_inputs(rules, value),
         {:ok, normalized} <- normalize_fields(rules, value, limits),
         :ok <- validate_cross_rules(rules, value, normalized, limits) do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_selection}
    end
  end

  def normalize(_rules, _value, _limits), do: {:error, :invalid_selection}

  @doc false
  @spec normalize_runtime(t(), term(), Limits.t()) ::
          {:ok, map()} | {:error, :invalid_selection}
  def normalize_runtime(%__MODULE__{} = rules, value, %Limits{} = limits)
      when is_map(value) and not is_struct(value) do
    case normalize(rules, value, limits) do
      {:ok, normalized} ->
        {:ok, normalized}

      {:error, :invalid_selection} ->
        input = Map.take(value, input_fields(rules))

        with {:ok, normalized} <- normalize(rules, input, limits),
             true <- normalized == value do
          {:ok, normalized}
        else
          _invalid -> {:error, :invalid_selection}
        end
    end
  end

  def normalize_runtime(_rules, _value, _limits), do: {:error, :invalid_selection}

  defp valid_shape?(rules) do
    is_map(rules.fields) and not is_struct(rules.fields) and
      map_size(rules.fields) <= @max_fields and
      Enum.all?(rules.fields, &valid_field?/1) and
      is_map(rules.named_sets) and not is_struct(rules.named_sets) and
      map_size(rules.named_sets) <= @max_named_sets and
      Enum.all?(rules.named_sets, &valid_named_set?/1) and
      is_list(rules.cross_rules) and length(rules.cross_rules) <= @max_fields * 3 and
      Enum.all?(rules.cross_rules, &valid_cross_rule?(&1, rules)) and
      defaults_reference_known_data?(rules) and literal_defaults_valid?(rules) and
      match?({:ok, _order}, field_order(rules))
  end

  defp valid_field?({name, field}) when is_binary(name) and is_map(field) do
    allowed = [
      :type,
      :input,
      :required,
      :default,
      :minimum,
      :maximum,
      :minimum_items,
      :members
    ]

    name =~ @name and Map.keys(field) -- allowed == [] and
      field[:input] in [true, false] and field[:required] in [nil, true, false] and
      (field[:required] != true or field[:input] == true) and
      valid_type?(field[:type]) and valid_integer_bounds?(field) and
      valid_list_bounds?(field) and
      valid_members_option?(field) and valid_default?(field)
  end

  defp valid_field?(_field), do: false

  defp valid_type?(type),
    do: type in [:string, :integer, :boolean, {:unique_list, :string}]

  defp valid_integer_bounds?(%{type: :integer} = field) do
    minimum = Map.get(field, :minimum)
    maximum = Map.get(field, :maximum)

    (is_nil(minimum) or is_integer(minimum)) and
      (is_nil(maximum) or is_integer(maximum)) and
      (is_nil(minimum) or is_nil(maximum) or minimum <= maximum)
  end

  defp valid_integer_bounds?(field),
    do: not Map.has_key?(field, :minimum) and not Map.has_key?(field, :maximum)

  defp valid_list_bounds?(%{type: {:unique_list, :string}} = field) do
    minimum_items = Map.get(field, :minimum_items, 0)
    is_integer(minimum_items) and minimum_items in 0..@max_set_items
  end

  defp valid_list_bounds?(field), do: not Map.has_key?(field, :minimum_items)

  defp valid_members_option?(%{members: set, type: type}),
    do: is_binary(set) and type in [:string, {:unique_list, :string}]

  defp valid_members_option?(field), do: not Map.has_key?(field, :members)

  defp valid_default?(field) do
    case Map.fetch(field, :default) do
      :error ->
        true

      {:ok, {:named_set, set}} ->
        field.type == {:unique_list, :string} and valid_name?(set)

      {:ok, {:intersection, other, set}} ->
        field.type == {:unique_list, :string} and valid_name?(other) and valid_name?(set)

      {:ok, value} ->
        valid_literal_default?(field.type, value)
    end
  end

  defp valid_literal_default?(:string, value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= 4_096

  defp valid_literal_default?(:integer, value), do: is_integer(value)
  defp valid_literal_default?(:boolean, value), do: is_boolean(value)

  defp valid_literal_default?({:unique_list, :string}, values)
       when is_list(values) and length(values) <= @max_set_items,
       do:
         values == Enum.uniq(values) and
           Enum.all?(values, &(is_binary(&1) and String.valid?(&1) and byte_size(&1) <= 4_096))

  defp valid_literal_default?(_type, _value), do: false

  defp valid_named_set?({name, values})
       when is_binary(name) and is_list(values) and length(values) <= @max_set_items do
    name =~ @name and values == Enum.sort(Enum.uniq(values)) and
      Enum.all?(values, &(is_binary(&1) and &1 =~ @name))
  end

  defp valid_named_set?(_set), do: false

  defp valid_name?(name), do: is_binary(name) and name =~ @name

  defp valid_cross_rule?({:subset_of, child, parent}, rules),
    do: list_field?(rules, child) and list_field?(rules, parent)

  defp valid_cross_rule?({:required_when_set_nonempty, field, set}, rules),
    do: input_field?(rules, field) and Map.has_key?(rules.named_sets, set)

  defp valid_cross_rule?({:ceiling_of_context_limit, field, limit}, rules),
    do:
      integer_field?(rules, field) and
        match?({:ok, _row}, LimitCatalog.fetch(limit))

  defp valid_cross_rule?(_rule, _rules), do: false

  defp defaults_reference_known_data?(rules) do
    Enum.all?(rules.fields, fn {_name, field} ->
      case Map.get(field, :default, :missing) do
        {:named_set, set} ->
          Map.has_key?(rules.named_sets, set)

        {:intersection, other, set} ->
          list_field?(rules, other) and Map.has_key?(rules.named_sets, set)

        _literal_or_missing ->
          true
      end
    end) and
      Enum.all?(rules.fields, fn {_name, field} ->
        is_nil(field[:members]) or Map.has_key?(rules.named_sets, field.members)
      end)
  end

  defp literal_defaults_valid?(rules) do
    Enum.all?(rules.fields, fn {_name, field} ->
      case Map.fetch(field, :default) do
        :error ->
          true

        {:ok, {:named_set, set}} ->
          match?(
            {:ok, _normalized},
            normalize_value(Map.fetch!(rules.named_sets, set), field, rules)
          )

        {:ok, {:intersection, _other, _set}} ->
          true

        {:ok, value} ->
          match?({:ok, _normalized}, normalize_value(value, field, rules))
      end
    end)
  end

  defp input_fields(rules) do
    for {name, %{input: true}} <- rules.fields, do: name
  end

  defp required_inputs(rules, value) do
    required =
      for {name, %{input: true, required: true}} <- rules.fields,
          not Map.has_key?(value, name),
          do: name

    if required == [], do: :ok, else: {:error, :required_selection_missing}
  end

  defp normalize_fields(rules, value, limits) do
    {:ok, order} = field_order(rules)

    order
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, normalized} ->
      field = Map.fetch!(rules.fields, name)

      case field_value(name, field, rules, value, normalized, limits) do
        {:ok, field_value} ->
          case normalize_value(field_value, field, rules) do
            {:ok, field_value} ->
              {:cont, {:ok, Map.put(normalized, name, field_value)}}

            :error ->
              {:halt, {:error, :invalid_selection}}
          end

        :omit ->
          {:cont, {:ok, normalized}}

        :error ->
          {:halt, {:error, :invalid_selection}}
      end
    end)
  end

  defp field_value(name, field, rules, value, normalized, limits) do
    case Map.fetch(value, name) do
      {:ok, field_value} ->
        {:ok, field_value}

      :error ->
        case Map.fetch(field, :default) do
          {:ok, default} ->
            resolve_default(default, rules, normalized)
            |> clamp_default_to_context(name, rules, limits)

          :error ->
            :omit
        end
    end
  end

  defp resolve_default({:named_set, set}, rules, _normalized),
    do: {:ok, Map.fetch!(rules.named_sets, set)}

  defp resolve_default({:intersection, field, set}, rules, normalized) do
    case Map.fetch(normalized, field) do
      {:ok, values} ->
        allowed = MapSet.new(Map.fetch!(rules.named_sets, set))
        {:ok, Enum.filter(values, &MapSet.member?(allowed, &1))}

      :error ->
        :error
    end
  end

  defp resolve_default(value, _rules, _normalized), do: {:ok, value}

  defp clamp_default_to_context({:ok, value}, name, rules, limits) when is_integer(value) do
    case Enum.find(rules.cross_rules, fn
           {:ceiling_of_context_limit, ^name, _limit} -> true
           _other -> false
         end) do
      {:ceiling_of_context_limit, ^name, limit} ->
        {:ok, min(value, Map.fetch!(limits, limit))}

      nil ->
        {:ok, value}
    end
  end

  defp clamp_default_to_context(result, _name, _rules, _limits), do: result

  defp normalize_value(value, %{type: :string} = field, rules)
       when is_binary(value) do
    if member?(value, field, rules), do: {:ok, value}, else: :error
  end

  defp normalize_value(value, %{type: :integer} = field, _rules)
       when is_integer(value) do
    minimum_valid? = not Map.has_key?(field, :minimum) or value >= field.minimum
    maximum_valid? = not Map.has_key?(field, :maximum) or value <= field.maximum

    if minimum_valid? and maximum_valid?, do: {:ok, value}, else: :error
  end

  defp normalize_value(value, %{type: :boolean}, _rules) when is_boolean(value),
    do: {:ok, value}

  defp normalize_value(value, %{type: {:unique_list, :string}} = field, rules)
       when is_list(value) and length(value) <= @max_set_items do
    minimum_items = Map.get(field, :minimum_items, 0)

    if length(value) >= minimum_items and value == Enum.uniq(value) and
         Enum.all?(value, &(is_binary(&1) and member?(&1, field, rules))) do
      {:ok, Enum.sort(value)}
    else
      :error
    end
  end

  defp normalize_value(_value, _field, _rules), do: :error

  defp member?(value, %{members: set}, rules),
    do: value in Map.fetch!(rules.named_sets, set)

  defp member?(_value, _field, _rules), do: true

  defp validate_cross_rules(rules, original, normalized, limits) do
    Enum.reduce_while(rules.cross_rules, :ok, fn rule, :ok ->
      if cross_rule_satisfied?(rule, rules, original, normalized, limits),
        do: {:cont, :ok},
        else: {:halt, {:error, :invalid_selection}}
    end)
  end

  defp cross_rule_satisfied?(
         {:subset_of, child, parent},
         _rules,
         _original,
         normalized,
         _limits
       ) do
    MapSet.subset?(
      MapSet.new(Map.get(normalized, child, [])),
      MapSet.new(Map.get(normalized, parent, []))
    )
  end

  defp cross_rule_satisfied?(
         {:required_when_set_nonempty, field, set},
         rules,
         original,
         normalized,
         _limits
       ) do
    Map.fetch!(rules.named_sets, set) == [] or
      (Map.has_key?(original, field) and Map.get(normalized, field, []) != [])
  end

  defp cross_rule_satisfied?(
         {:ceiling_of_context_limit, field, limit},
         _rules,
         _original,
         normalized,
         limits
       ) do
    case Map.fetch(normalized, field) do
      {:ok, value} -> is_integer(value) and value <= Map.fetch!(limits, limit)
      :error -> true
    end
  end

  defp input_field?(rules, name),
    do: match?(%{input: true}, Map.get(rules.fields, name))

  defp integer_field?(rules, name),
    do: match?(%{type: :integer}, Map.get(rules.fields, name))

  defp list_field?(rules, name),
    do: match?(%{type: {:unique_list, :string}}, Map.get(rules.fields, name))

  defp field_order(rules) do
    dependencies =
      Map.new(rules.fields, fn {name, field} ->
        dependency =
          case Map.get(field, :default) do
            {:intersection, other, _set} -> MapSet.new([other])
            _default -> MapSet.new()
          end

        {name, dependency}
      end)

    dependents =
      Enum.reduce(dependencies, %{}, fn {name, required}, acc ->
        Enum.reduce(required, acc, fn dependency, nested ->
          Map.update(nested, dependency, [name], &[name | &1])
        end)
      end)

    ready =
      dependencies
      |> Enum.filter(fn {_name, required} -> MapSet.size(required) == 0 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    drain_field_order(ready, dependencies, dependents, [])
  end

  defp drain_field_order([], dependencies, _dependents, order) do
    if length(order) == map_size(dependencies), do: {:ok, Enum.reverse(order)}, else: :error
  end

  defp drain_field_order([name | ready], dependencies, dependents, order) do
    {dependencies, newly_ready} =
      Enum.reduce(Map.get(dependents, name, []), {dependencies, []}, fn dependent,
                                                                        {remaining, newly_ready} ->
        required = remaining |> Map.fetch!(dependent) |> MapSet.delete(name)
        remaining = Map.put(remaining, dependent, required)

        newly_ready =
          if MapSet.size(required) == 0, do: [dependent | newly_ready], else: newly_ready

        {remaining, newly_ready}
      end)

    drain_field_order(
      Enum.sort(ready ++ newly_ready),
      dependencies,
      dependents,
      [name | order]
    )
  end

  defp payload(rules), do: {rules.fields, rules.cross_rules, rules.named_sets}
end
