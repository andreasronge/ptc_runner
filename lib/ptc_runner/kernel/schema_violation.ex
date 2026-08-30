defmodule PtcRunner.Kernel.SchemaViolation do
  @moduledoc """
  Bounded, value-free projection of a JSON Schema validation failure.

  Validator errors may retain the rejected document, caller-authored property
  names, schema internals, and every rejected branch of a tagged union. This
  projection keeps only a closed rule atom and a path explained by the schema
  that rejected the document. Missing required properties may extend the
  validator's parent path only when the schema authorizes the missing name;
  unknown properties never retain their caller-authored key.

  For a rejected `oneOf`, the branch with no discriminator failure and the
  smallest bounded error set wins. This keeps a tagged installation's real
  failure instead of reporting the unrelated required fields or closed keys of
  every other installation variant.
  """

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.SchemaPath

  @max_branch_depth 12
  @validation_timeout_ms 1_000
  @validation_max_heap_words 2_000_000
  @rules [
    :const,
    :contains,
    :duplicate_property,
    :enum,
    :max_items,
    :max_length,
    :max_properties,
    :maximum,
    :min_items,
    :min_length,
    :min_properties,
    :minimum,
    :multiple_of,
    :not,
    :one_of,
    :pattern,
    :required,
    :schema,
    :type,
    :unique_items,
    :unknown_property
  ]

  @enforce_keys [:rule, :path]
  defstruct @enforce_keys

  @type rule ::
          :const
          | :contains
          | :duplicate_property
          | :enum
          | :max_items
          | :max_length
          | :max_properties
          | :maximum
          | :min_items
          | :min_length
          | :min_properties
          | :minimum
          | :multiple_of
          | :not
          | :one_of
          | :pattern
          | :required
          | :schema
          | :type
          | :unique_items
          | :unknown_property

  @type t :: %__MODULE__{rule: rule(), path: [CommandPath.segment()]}
  @type unavailable_reason :: :timeout | :cancelled | :heap_exceeded | :worker_failed

  @doc "Projects one JSV error list through the schema that rejected it."
  @spec from_jsv([term()], map()) :: t()
  def from_jsv(errors, schema) when is_list(errors) and is_map(schema) do
    errors
    |> candidates(schema, @max_branch_depth)
    |> best_candidate()
  rescue
    _exception -> new(:schema, [])
  catch
    _kind, _reason -> new(:schema, [])
  end

  def from_jsv(_errors, _schema), do: new(:schema, [])

  @doc "Validates one value, retries one timeout, and distinguishes unavailable bounded work."
  @spec validate(term(), map()) :: :ok | {:error, t()} | {:unavailable, unavailable_reason()}
  def validate(value, schema) when is_map(schema) do
    validate_bounded(value, schema, true)
  end

  def validate(_value, _schema), do: {:error, new(:schema, [])}

  defp validate_bounded(value, schema, retry_timeout?) do
    case BoundedWorker.run(
           fn -> validate_unbounded(value, schema) end,
           timeout_ms: @validation_timeout_ms,
           max_heap_words: @validation_max_heap_words
         ) do
      {:ok, result} -> result
      {:error, :timeout} when retry_timeout? -> validate_bounded(value, schema, false)
      {:error, reason} -> {:unavailable, reason}
    end
  end

  @doc "Builds a bounded violation from an already schema-authorized path."
  @spec new(rule(), [CommandPath.segment()]) :: t()
  def new(rule, path) when rule in @rules and is_list(path) do
    if Enum.all?(path, &valid_segment?/1),
      do: %__MODULE__{rule: rule, path: path},
      else: %__MODULE__{rule: :schema, path: []}
  end

  def new(_rule, _path), do: %__MODULE__{rule: :schema, path: []}

  @doc false
  @spec rules() :: [rule()]
  def rules, do: @rules

  defp candidates(errors, schema, depth) when is_list(errors) and depth > 0,
    do: Enum.flat_map(errors, &candidates(&1, schema, depth))

  defp candidates(%{kind: :oneOf, args: args} = error, schema, depth) when depth > 0 do
    if zero_validated_branches?(args) do
      branches = invalidated_branches(args)
      union_path = reverse_data_path(error)

      case best_branch(branches, schema, union_path, depth - 1) do
        [] -> candidate(error, schema, :one_of)
        selected -> selected
      end
    else
      candidate(error, schema, :one_of)
    end
  end

  defp candidates(%{kind: kind} = error, schema, depth) when depth > 0 do
    direct =
      case rule(kind, Map.get(error, :args)) do
        nil -> []
        rule -> candidate(error, schema, rule)
      end

    direct ++ nested_candidates(Map.get(error, :args), schema, depth - 1)
  end

  defp candidates(_error, _schema, _depth), do: []

  defp invalidated_branches(args) when is_list(args) do
    args
    |> Keyword.get_values(:invalidated)
    |> Enum.concat()
    |> Enum.flat_map(fn
      {_index, %{errors: errors}} when is_list(errors) -> [errors]
      _other -> []
    end)
  end

  defp zero_validated_branches?(args) when is_list(args),
    do: Keyword.get(args, :validated, :metadata_absent) == []

  defp zero_validated_branches?(_args), do: false

  defp best_branch(branches, schema, union_path, depth) do
    discriminator_fields = discriminator_fields(schema, union_path)

    branches
    |> Enum.map(&candidates(&1, schema, depth))
    |> Enum.reject(&(&1 == []))
    |> Enum.min_by(&branch_score(&1, union_path, discriminator_fields), fn -> [] end)
  end

  defp branch_score(candidates, union_path, discriminator_fields) do
    discriminator_failures =
      Enum.count(candidates, &discriminator_failure?(&1, union_path, discriminator_fields))

    required_failures = Enum.count(candidates, &(&1.rule == :required))
    deepest = candidates |> Enum.map(&length(&1.path)) |> Enum.max(fn -> 0 end)
    {discriminator_failures, required_failures, length(candidates), -deepest}
  end

  defp discriminator_failure?(candidate, union_path, discriminator_fields) do
    candidate.rule in [:const, :enum] and
      Enum.any?(discriminator_fields, &(candidate.raw_path == union_path ++ [&1]))
  end

  defp discriminator_fields(schema, union_path) do
    union_path
    |> SchemaPath.schemas_at(schema)
    |> Enum.find_value(MapSet.new(), fn
      %{"oneOf" => branches} when is_list(branches) and length(branches) > 1 ->
        branch_discriminator_fields(branches)

      _schema ->
        false
    end)
  end

  defp branch_discriminator_fields(branches) do
    constraints = Enum.map(branches, &tag_constraints/1)

    constraints
    |> common_keys()
    |> Enum.filter(fn field ->
      constraints
      |> Enum.map(&Map.fetch!(&1, field))
      |> Enum.uniq()
      |> length() > 1
    end)
    |> MapSet.new()
  end

  defp tag_constraints(%{"properties" => properties}) when is_map(properties) do
    Map.new(properties, fn
      {field, %{"const" => value}} -> {field, {:values, [value]}}
      {field, %{"enum" => values}} when is_list(values) -> {field, {:values, values}}
      {field, _schema} -> {field, :not_a_tag}
    end)
    |> Map.reject(fn {_field, constraint} -> constraint == :not_a_tag end)
  end

  defp tag_constraints(_schema), do: %{}

  defp common_keys([]), do: []

  defp common_keys([first | rest]) do
    Enum.reduce(rest, Map.keys(first), fn constraints, fields ->
      Enum.filter(fields, &Map.has_key?(constraints, &1))
    end)
  end

  defp nested_candidates(args, schema, depth) when is_list(args) and depth > 0 do
    args
    |> Keyword.take([:after_err_vctx])
    |> Keyword.values()
    |> Enum.flat_map(fn
      %{errors: errors} when is_list(errors) -> candidates(errors, schema, depth)
      _other -> []
    end)
  end

  defp nested_candidates(_args, _schema, _depth), do: []

  defp candidate(%{data_path: reverse_path} = error, schema, rule)
       when is_list(reverse_path) do
    raw_path = Enum.reverse(reverse_path) ++ required_suffix(error, rule)

    [
      %{
        rule: rule,
        path: SchemaPath.explained_prefix(raw_path, schema),
        raw_path: raw_path
      }
    ]
  end

  defp candidate(_error, _schema, _rule), do: []

  defp required_suffix(%{args: args}, :required) when is_list(args) do
    args
    |> Keyword.get(:required, [])
    |> Enum.filter(&is_binary/1)
    |> Enum.take(1)
  end

  defp required_suffix(_error, _rule), do: []

  defp best_candidate([]), do: new(:schema, [])

  defp best_candidate(candidates) do
    %{rule: rule, path: path} =
      Enum.min_by(candidates, fn violation ->
        {-length(violation.path), rule_priority(violation.rule), violation.path}
      end)

    new(rule, path)
  end

  defp rule(:additionalProperties, args) when is_list(args) do
    if Keyword.get(args, :boolean_schema_false, false), do: :unknown_property, else: nil
  end

  defp rule(:type, _args), do: :type
  defp rule(:contains, _args), do: :contains
  defp rule(:minContains, _args), do: :contains
  defp rule(:not, _args), do: :not
  defp rule(:required, _args), do: :required
  defp rule(:minimum, _args), do: :minimum
  defp rule(:maximum, _args), do: :maximum
  defp rule(:pattern, _args), do: :pattern
  defp rule(:const, _args), do: :const
  defp rule(:enum, _args), do: :enum
  defp rule(:multipleOf, _args), do: :multiple_of
  defp rule(:minLength, _args), do: :min_length
  defp rule(:maxLength, _args), do: :max_length
  defp rule(:minItems, _args), do: :min_items
  defp rule(:maxItems, _args), do: :max_items
  defp rule(:minProperties, _args), do: :min_properties
  defp rule(:maxProperties, _args), do: :max_properties
  defp rule(:uniqueItems, _args), do: :unique_items
  defp rule(_kind, _args), do: nil

  defp rule_priority(rule) when rule in [:one_of, :schema], do: 1
  defp rule_priority(_rule), do: 0

  defp valid_segment?({:property, name}), do: is_binary(name)
  defp valid_segment?({:index, index}), do: is_integer(index) and index >= 0
  defp valid_segment?(_segment), do: false

  defp reverse_data_path(%{data_path: reverse_path}) when is_list(reverse_path),
    do: Enum.reverse(reverse_path)

  defp reverse_data_path(_error), do: []

  defp validate_unbounded(value, schema) do
    case JSV.build(schema, atoms: false, warnings: :silent) do
      {:ok, root} ->
        case JSV.validate(value, root, cast: false) do
          {:ok, _validated} -> :ok
          {:error, %JSV.ValidationError{errors: errors}} -> {:error, from_jsv(errors, schema)}
        end

      {:error, _reason} ->
        {:error, new(:schema, [])}
    end
  rescue
    _exception -> {:error, new(:schema, [])}
  catch
    _kind, _reason -> {:error, new(:schema, [])}
  end
end
