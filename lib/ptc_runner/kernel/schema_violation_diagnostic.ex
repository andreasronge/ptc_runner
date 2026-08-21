defmodule PtcRunner.Kernel.SchemaViolationDiagnostic do
  @moduledoc """
  Closed messages for hand-authored document schema violations.

  Messages name only the document role and a bounded rule projected by
  `PtcRunner.Kernel.SchemaViolation`. Rejected values, caller-authored keys,
  installation aliases, and filesystem names never cross this boundary.
  """

  alias PtcRunner.Kernel.SchemaViolation

  @roles %{
    host: "the host configuration",
    application: "the application manifest"
  }

  @application_rules [
    :const,
    :enum,
    :max_items,
    :max_length,
    :max_properties,
    :maximum,
    :min_length,
    :minimum,
    :one_of,
    :pattern,
    :required,
    :schema,
    :type,
    :unique_items,
    :unknown_property
  ]

  @role_rules %{
    host: SchemaViolation.rules(),
    application: @application_rules
  }

  @rule_suffixes %{
    const: "violates the const schema rule",
    contains: "violates the contains schema rule",
    duplicate_property: "contains a duplicate property",
    enum: "violates the enum schema rule",
    max_items: "violates the maxItems schema rule",
    max_length: "violates the maxLength schema rule",
    max_properties: "violates the maxProperties schema rule",
    maximum: "violates the maximum schema rule",
    min_items: "violates the minItems schema rule",
    min_length: "violates the minLength schema rule",
    min_properties: "violates the minProperties schema rule",
    minimum: "violates the minimum schema rule",
    multiple_of: "violates the multipleOf schema rule",
    not: "violates the not schema rule",
    one_of: "violates the oneOf schema rule",
    pattern: "violates the pattern schema rule",
    required: "is missing a required property",
    schema: "does not satisfy its schema",
    type: "violates the type schema rule",
    unique_items: "violates the uniqueItems schema rule",
    unknown_property: "contains an unknown property"
  }

  if Enum.sort(Map.keys(@rule_suffixes)) != Enum.sort(SchemaViolation.rules()) do
    raise "schema violation rules and messages drifted apart"
  end

  if Enum.any?(@role_rules, fn {role, rules} ->
       not Map.has_key?(@roles, role) or rules -- SchemaViolation.rules() != []
     end) do
    raise "schema violation role rules are invalid"
  end

  @doc false
  @spec rules(atom(), atom()) :: [SchemaViolation.rule()]
  def rules(:host, :host_schema_invalid), do: @role_rules.host
  def rules(:application, :required_property_missing), do: [:required]
  def rules(:application, :schema_violation), do: @role_rules.application -- [:required]
  def rules(_role, _code), do: []

  @doc "Renders a fixed document-role/rule message."
  @spec message(atom(), SchemaViolation.rule()) :: {:ok, binary()} | :error
  def message(role, rule) do
    with {:ok, prefix} <- Map.fetch(@roles, role),
         {:ok, rules} <- Map.fetch(@role_rules, role),
         true <- rule in rules,
         {:ok, suffix} <- Map.fetch(@rule_suffixes, rule) do
      {:ok, prefix <> " " <> suffix}
    else
      _unknown -> :error
    end
  end

  @doc false
  @spec valid_message?(atom(), [SchemaViolation.rule()], term()) :: boolean()
  def valid_message?(role, rules, message) when is_list(rules) and is_binary(message),
    do: message in messages(role, rules)

  def valid_message?(_role, _rules, _message), do: false

  @doc false
  @spec messages(atom(), [SchemaViolation.rule()]) :: [binary()]
  def messages(role, rules), do: rules |> Enum.flat_map(&message_list(role, &1)) |> Enum.sort()

  @doc false
  @spec message_schema(atom(), [SchemaViolation.rule()], binary()) :: map()
  def message_schema(role, rules, fallback) when is_list(rules) and is_binary(fallback),
    do: %{"enum" => [fallback | messages(role, rules)] |> Enum.uniq() |> Enum.sort()}

  defp message_list(role, rule) do
    case message(role, rule) do
      {:ok, message} -> [message]
      :error -> []
    end
  end
end
