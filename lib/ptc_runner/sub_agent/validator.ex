defmodule PtcRunner.SubAgent.Validator do
  @moduledoc """
  Validates SubAgent options at construction time.

  Ensures required fields are present and all optional fields have valid types.
  Extracted from `PtcRunner.SubAgent` to keep that module under the 800-line threshold.
  """

  @doc """
  Validates all SubAgent options, raising on invalid input.

  ## Raises

  - `ArgumentError` - if any validation fails
  """
  @spec validate!(keyword()) :: :ok
  def validate!(opts) do
    validate_required_fields!(opts)
    validate_types!(opts)
    :ok
  end

  # Validate that required field is present
  defp validate_required_fields!(opts) do
    case Keyword.fetch(opts, :prompt) do
      {:ok, _} -> :ok
      :error -> raise ArgumentError, "prompt is required"
    end
  end

  # Validate types of provided fields
  defp validate_types!(opts) do
    validate_prompt!(opts)
    validate_tools!(opts)
    validate_max_turns!(opts)
    validate_retry_turns!(opts)
    validate_timeout!(opts)
    validate_mission_timeout!(opts)
    validate_signature!(opts)
    validate_llm_retry!(opts)
    validate_prompt_limit!(opts)
    validate_memory_limit!(opts)
    validate_max_depth!(opts)
    validate_turn_budget!(opts)
    validate_prompt_placeholders!(opts)
    validate_name!(opts)
    validate_description!(opts)
    validate_field_descriptions!(opts)
    validate_context_descriptions!(opts)
    validate_format_options!(opts)
    validate_builtin_tools!(opts)
    validate_output!(opts)
    validate_thinking!(opts)
    validate_memory_strategy!(opts)
    validate_max_tool_calls!(opts)
    validate_journaling!(opts)
    validate_self_tool_requires_signature!(opts)
  end

  defp validate_prompt!(opts) do
    case Keyword.fetch(opts, :prompt) do
      {:ok, prompt} when is_binary(prompt) -> :ok
      {:ok, _} -> raise ArgumentError, "prompt must be a string"
      :error -> :ok
    end
  end

  defp validate_tools!(opts) do
    case Keyword.fetch(opts, :tools) do
      {:ok, tools} when is_map(tools) -> :ok
      {:ok, _} -> raise ArgumentError, "tools must be a map"
      :error -> :ok
    end
  end

  defp validate_max_turns!(opts) do
    case Keyword.fetch(opts, :max_turns) do
      {:ok, max_turns} when is_integer(max_turns) and max_turns > 0 -> :ok
      {:ok, _} -> raise ArgumentError, "max_turns must be a positive integer"
      :error -> :ok
    end
  end

  defp validate_retry_turns!(opts) do
    case Keyword.fetch(opts, :retry_turns) do
      {:ok, retries} when is_integer(retries) and retries >= 0 -> :ok
      {:ok, _} -> raise ArgumentError, "retry_turns must be a non-negative integer"
      :error -> :ok
    end
  end

  defp validate_timeout!(opts) do
    case Keyword.fetch(opts, :timeout) do
      {:ok, timeout} when is_integer(timeout) and timeout > 0 -> :ok
      {:ok, nil} -> raise ArgumentError, "timeout cannot be nil"
      {:ok, _} -> raise ArgumentError, "timeout must be a positive integer"
      :error -> :ok
    end
  end

  defp validate_mission_timeout!(opts) do
    case Keyword.fetch(opts, :mission_timeout) do
      {:ok, timeout} when is_integer(timeout) and timeout > 0 -> :ok
      {:ok, nil} -> :ok
      {:ok, _} -> raise ArgumentError, "mission_timeout must be a positive integer or nil"
      :error -> :ok
    end
  end

  defp validate_signature!(opts) do
    alias PtcRunner.SubAgent.Signature

    case Keyword.fetch(opts, :signature) do
      {:ok, sig} when is_binary(sig) ->
        # Validate that signature parses correctly (fail fast)
        case Signature.parse(sig) do
          {:ok, _} -> :ok
          {:error, reason} -> raise ArgumentError, "invalid signature: #{reason}"
        end

      {:ok, _} ->
        raise ArgumentError, "signature must be a string"

      :error ->
        :ok
    end
  end

  defp validate_llm_retry!(opts) do
    case Keyword.fetch(opts, :llm_retry) do
      {:ok, retry} when is_map(retry) -> :ok
      {:ok, _} -> raise ArgumentError, "llm_retry must be a map"
      :error -> :ok
    end
  end

  defp validate_prompt_limit!(opts) do
    case Keyword.fetch(opts, :prompt_limit) do
      {:ok, limit} when is_map(limit) -> :ok
      {:ok, _} -> raise ArgumentError, "prompt_limit must be a map"
      :error -> :ok
    end
  end

  defp validate_memory_limit!(opts) do
    case Keyword.fetch(opts, :memory_limit) do
      {:ok, limit} when is_integer(limit) and limit > 0 -> :ok
      {:ok, nil} -> :ok
      {:ok, _} -> raise ArgumentError, "memory_limit must be a positive integer or nil"
      :error -> :ok
    end
  end

  defp validate_max_depth!(opts) do
    case Keyword.fetch(opts, :max_depth) do
      {:ok, depth} when is_integer(depth) and depth > 0 -> :ok
      {:ok, _} -> raise ArgumentError, "max_depth must be a positive integer"
      :error -> :ok
    end
  end

  defp validate_turn_budget!(opts) do
    case Keyword.fetch(opts, :turn_budget) do
      {:ok, budget} when is_integer(budget) and budget > 0 -> :ok
      {:ok, _} -> raise ArgumentError, "turn_budget must be a positive integer"
      :error -> :ok
    end
  end

  # Validate that prompt placeholders match signature parameters
  defp validate_prompt_placeholders!(opts) do
    alias PtcRunner.SubAgent.PromptExpander

    prompt_text = Keyword.get(opts, :prompt)

    with prompt when is_binary(prompt) <- prompt_text,
         {:ok, signature} <- Keyword.fetch(opts, :signature) do
      placeholders = PromptExpander.extract_placeholder_names(prompt)
      signature_params = PromptExpander.extract_signature_params(signature)

      case placeholders -- signature_params do
        [] ->
          :ok

        missing ->
          formatted_missing = Enum.map_join(missing, ", ", &"{{#{&1}}}")

          raise ArgumentError,
                "placeholders #{formatted_missing} not found in signature"
      end
    else
      _ -> :ok
    end
  end

  defp validate_name!(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> :ok
      {:ok, name} when is_binary(name) and name != "" -> :ok
      {:ok, ""} -> raise ArgumentError, "name must be a non-empty string or nil"
      {:ok, _} -> raise ArgumentError, "name must be a string"
      :error -> :ok
    end
  end

  defp validate_description!(opts) do
    case Keyword.fetch(opts, :description) do
      {:ok, nil} -> :ok
      {:ok, desc} when is_binary(desc) and desc != "" -> :ok
      {:ok, ""} -> raise ArgumentError, "description must be a non-empty string or nil"
      {:ok, _} -> raise ArgumentError, "description must be a string"
      :error -> :ok
    end
  end

  defp validate_field_descriptions!(opts) do
    case Keyword.fetch(opts, :field_descriptions) do
      {:ok, nil} -> :ok
      {:ok, fd} when is_map(fd) -> :ok
      {:ok, _} -> raise ArgumentError, "field_descriptions must be a map"
      :error -> :ok
    end
  end

  defp validate_context_descriptions!(opts) do
    case Keyword.fetch(opts, :context_descriptions) do
      {:ok, nil} -> :ok
      {:ok, cd} when is_map(cd) -> :ok
      {:ok, _} -> raise ArgumentError, "context_descriptions must be a map"
      :error -> :ok
    end
  end

  defp validate_format_options!(opts) do
    case Keyword.fetch(opts, :format_options) do
      {:ok, fo} when is_list(fo) -> :ok
      {:ok, _} -> raise ArgumentError, "format_options must be a keyword list"
      :error -> :ok
    end
  end

  defp validate_builtin_tools!(opts) do
    case Keyword.fetch(opts, :builtin_tools) do
      {:ok, tools} when is_list(tools) ->
        unless Enum.all?(tools, &is_atom/1) do
          raise ArgumentError, "builtin_tools must be a list of atoms"
        end

      {:ok, _} ->
        raise ArgumentError, "builtin_tools must be a list of atoms"

      :error ->
        :ok
    end
  end

  defp validate_output!(opts) do
    case Keyword.fetch(opts, :output) do
      {:ok, :ptc_lisp} ->
        :ok

      {:ok, :json} ->
        validate_json_mode_constraints!(opts)

      {:ok, other} ->
        raise ArgumentError,
              "output must be :ptc_lisp or :json, got #{inspect(other)}"

      :error ->
        # Default is :ptc_lisp, no validation needed
        :ok
    end
  end

  defp validate_json_mode_constraints!(opts) do
    # JSON mode requires: no tools, no compression, has signature, no firewall fields
    validate_json_no_tools!(opts)
    validate_json_no_compression!(opts)
    validate_json_has_signature!(opts)
    validate_json_no_firewall_fields!(opts)
    validate_json_all_params_used!(opts)
    validate_section_fields!(opts)
  end

  defp validate_json_no_tools!(opts) do
    case Keyword.fetch(opts, :tools) do
      {:ok, tools} when map_size(tools) > 0 ->
        raise ArgumentError, "output: :json cannot be used with tools"

      _ ->
        :ok
    end
  end

  defp validate_json_no_compression!(opts) do
    case Keyword.fetch(opts, :compression) do
      {:ok, compression} when compression not in [nil, false] ->
        raise ArgumentError, "output: :json cannot be used with compression"

      _ ->
        :ok
    end
  end

  defp validate_json_has_signature!(opts) do
    case Keyword.fetch(opts, :signature) do
      {:ok, sig} when is_binary(sig) ->
        :ok

      _ ->
        raise ArgumentError, "output: :json requires a signature"
    end
  end

  defp validate_json_no_firewall_fields!(opts) do
    alias PtcRunner.SubAgent.Signature

    case Keyword.fetch(opts, :signature) do
      {:ok, sig} when is_binary(sig) ->
        case Signature.parse(sig) do
          {:ok, {:signature, _params, output_type}} ->
            case find_firewall_field(output_type) do
              nil ->
                :ok

              field_name ->
                raise ArgumentError,
                      "output: :json signature cannot have firewall fields (#{field_name})"
            end

          # Signature parsing error already handled by validate_signature!
          {:error, _} ->
            :ok
        end

      _ ->
        # No signature case already handled by validate_json_has_signature!
        :ok
    end
  end

  # Recursively check a type for firewall fields (fields starting with "_")
  # Returns the first firewall field name found, or nil if none
  defp find_firewall_field({:map, fields}) do
    Enum.find_value(fields, fn {field_name, field_type} ->
      if String.starts_with?(field_name, "_") do
        field_name
      else
        find_firewall_field(field_type)
      end
    end)
  end

  defp find_firewall_field({:list, element_type}) do
    find_firewall_field(element_type)
  end

  defp find_firewall_field({:optional, inner_type}) do
    find_firewall_field(inner_type)
  end

  # Primitives and other types don't contain fields
  defp find_firewall_field(_), do: nil

  # JSON mode: validate all signature params are used in prompt (via variables or sections)
  defp validate_json_all_params_used!(opts) do
    alias PtcRunner.SubAgent.{PromptExpander, Signature}

    prompt = Keyword.get(opts, :prompt)
    signature = Keyword.get(opts, :signature)

    with true <- is_binary(prompt),
         true <- is_binary(signature),
         {:ok, {:signature, params, _}} <- Signature.parse(signature) do
      # Get all params used in prompt (including section names and inverted sections)
      used_params = extract_all_used_params(prompt)

      # Get signature param names
      signature_params = Enum.map(params, fn {name, _type} -> name end) |> MapSet.new()

      # Find unused params
      unused = MapSet.difference(signature_params, used_params)

      if MapSet.size(unused) > 0 do
        unused_list = unused |> MapSet.to_list() |> Enum.sort()

        raise ArgumentError,
              "JSON mode requires all signature params in prompt. Unused: #{inspect(unused_list)}"
      end
    end

    :ok
  end

  # Extract all param names used in prompt (from variables, sections, inverted sections)
  defp extract_all_used_params(prompt) do
    alias PtcRunner.SubAgent.PromptExpander

    # Get full Mustache variable info including sections
    variables = PromptExpander.extract_placeholders_with_sections(prompt)

    # Collect all top-level param names (first element of path)
    variables
    |> Enum.flat_map(&collect_param_names/1)
    |> MapSet.new()
  end

  # Collect param names from variable info (recursively for sections)
  defp collect_param_names(%{type: type, path: path, fields: fields})
       when type in [:section, :inverted_section] do
    # Section name counts as "used"
    section_name = hd(path)

    # Also collect any nested variable names within the section
    nested_names =
      if is_list(fields) do
        Enum.flat_map(fields, &collect_param_names/1)
      else
        []
      end

    [section_name | nested_names]
  end

  defp collect_param_names(%{type: :simple, path: path}) do
    # For simple variables, only the first path element is a param
    [hd(path)]
  end

  # Validate section fields against signature types
  defp validate_section_fields!(opts) do
    alias PtcRunner.SubAgent.{PromptExpander, Signature}
    alias PtcRunner.SubAgent.Signature.TypeResolver

    prompt = Keyword.get(opts, :prompt)
    signature = Keyword.get(opts, :signature)

    with true <- is_binary(prompt),
         true <- is_binary(signature),
         {:ok, parsed_sig} <- Signature.parse(signature) do
      # Get full Mustache variable info including sections
      variables = PromptExpander.extract_placeholders_with_sections(prompt)

      # Validate each section recursively
      errors = validate_variables_recursive(variables, parsed_sig, [])

      if errors != [] do
        error_msg = format_section_errors(errors)
        raise ArgumentError, error_msg
      end
    end

    :ok
  end

  # Recursively validate variables against signature
  defp validate_variables_recursive([], _parsed_sig, errors), do: errors

  defp validate_variables_recursive([var | rest], parsed_sig, errors) do
    new_errors = validate_variable(var, parsed_sig)
    validate_variables_recursive(rest, parsed_sig, errors ++ new_errors)
  end

  # Validate a single variable (simple or section)
  defp validate_variable(%{type: :simple, path: ["."], loc: loc}, _parsed_sig) do
    # {{.}} is valid only inside sections, and should refer to scalar element type
    # This is handled at the section level, not here
    # If we see {{.}} at top level, it's an error
    [{:dot_outside_section, loc}]
  end

  defp validate_variable(%{type: :simple, path: path}, parsed_sig) do
    alias PtcRunner.SubAgent.Signature.TypeResolver

    param_name = hd(path)

    case TypeResolver.resolve_path(parsed_sig, [param_name]) do
      {:ok, _type} -> []
      {:error, {:param_not_found, _}} -> [{:param_not_found, param_name}]
    end
  end

  defp validate_variable(
         %{type: type, path: [section_name], fields: fields, loc: loc},
         parsed_sig
       )
       when type in [:section, :inverted_section] do
    alias PtcRunner.SubAgent.Signature.TypeResolver

    # Check if section name is a valid param
    case TypeResolver.resolve_path(parsed_sig, [section_name]) do
      {:ok, param_type} ->
        # For sections, validate fields based on the param type
        validate_section_fields_against_type(fields, param_type, section_name, loc)

      {:error, {:param_not_found, _}} ->
        [{:section_param_not_found, section_name, loc}]
    end
  end

  # Validate section fields against the expected type
  defp validate_section_fields_against_type(nil, _type, _section_name, _loc), do: []
  defp validate_section_fields_against_type([], _type, _section_name, _loc), do: []

  defp validate_section_fields_against_type(fields, {:list, element_type}, section_name, _loc) do
    # For list sections, validate fields against element type
    validate_section_fields_list(fields, element_type, section_name)
  end

  defp validate_section_fields_against_type(fields, {:map, map_fields}, section_name, _loc) do
    # For map sections (context push), validate fields against map fields
    validate_section_fields_map(fields, map_fields, section_name)
  end

  defp validate_section_fields_against_type(fields, {:optional, inner}, section_name, loc) do
    validate_section_fields_against_type(fields, inner, section_name, loc)
  end

  defp validate_section_fields_against_type(_fields, _scalar_type, _section_name, _loc) do
    # Scalar types (bool, etc.) are valid for truthy checks, no field validation needed
    []
  end

  # Validate fields inside a list section
  defp validate_section_fields_list(fields, {:map, map_fields}, section_name) do
    # List of maps: validate each field reference
    Enum.flat_map(fields, fn
      %{type: :simple, path: ["."], loc: loc} ->
        # {{.}} inside list of maps is an error
        [{:dot_on_map_list, section_name, loc}]

      %{type: :simple, path: [field_name]} ->
        # Check if field exists in map type
        if Enum.any?(map_fields, fn {name, _} -> name == field_name end) do
          []
        else
          [{:field_not_in_signature, field_name, section_name}]
        end

      %{type: :simple, path: _nested_path} ->
        # Nested access like {{user.name}} - would need deeper validation
        []

      %{type: type, path: [nested_section], fields: nested_fields, loc: loc}
      when type in [:section, :inverted_section] ->
        # Nested section - validate recursively
        nested_type =
          Enum.find_value(map_fields, nil, fn
            {name, field_type} when name == nested_section -> field_type
            _ -> nil
          end)

        if nested_type do
          validate_section_fields_against_type(nested_fields, nested_type, nested_section, loc)
        else
          [{:field_not_in_signature, nested_section, section_name}]
        end
    end)
  end

  defp validate_section_fields_list(fields, scalar_type, section_name) do
    # List of scalars: only {{.}} is valid
    alias PtcRunner.SubAgent.Signature.TypeResolver

    Enum.flat_map(fields, fn
      %{type: :simple, path: ["."]} ->
        # {{.}} is valid for scalar lists
        []

      %{type: :simple, path: [field_name], loc: loc} ->
        if TypeResolver.scalar_type?(scalar_type) do
          # Trying to access field on scalar element
          [{:field_on_scalar, field_name, section_name, scalar_type, loc}]
        else
          []
        end

      _ ->
        []
    end)
  end

  # Validate fields inside a map section (context push)
  defp validate_section_fields_map(fields, map_fields, section_name) do
    Enum.flat_map(fields, fn
      %{type: :simple, path: [field_name]} ->
        if Enum.any?(map_fields, fn {name, _} -> name == field_name end) do
          []
        else
          [{:field_not_in_signature, field_name, section_name}]
        end

      _ ->
        []
    end)
  end

  # Format validation errors for display
  defp format_section_errors(errors) do
    messages =
      Enum.map(errors, fn
        {:dot_outside_section, loc} ->
          "{{.}} at line #{loc.line} can only be used inside sections"

        {:dot_on_map_list, section_name, loc} ->
          "{{.}} at line #{loc.line} inside {{##{section_name}}} - use {{field}} instead (list contains maps)"

        {:param_not_found, param_name} ->
          "{{#{param_name}}} not found in signature parameters"

        {:section_param_not_found, section_name, _loc} ->
          "{{##{section_name}}} not found in signature parameters"

        {:field_not_in_signature, field_name, section_name} ->
          "{{#{field_name}}} inside {{##{section_name}}} not found in element type"

        {:field_on_scalar, field_name, section_name, scalar_type, _loc} ->
          "{{#{field_name}}} inside {{##{section_name}}} - cannot access field on #{scalar_type}. Use {{.}} instead."
      end)

    Enum.join(messages, "; ")
  end

  defp validate_thinking!(opts) do
    case Keyword.fetch(opts, :thinking) do
      {:ok, val} when is_boolean(val) -> :ok
      {:ok, _} -> raise ArgumentError, "thinking must be a boolean"
      :error -> :ok
    end
  end

  defp validate_memory_strategy!(opts) do
    case Keyword.fetch(opts, :memory_strategy) do
      {:ok, strategy} when strategy in [:strict, :rollback] ->
        :ok

      {:ok, other} ->
        raise ArgumentError, "memory_strategy must be :strict or :rollback, got #{inspect(other)}"

      :error ->
        :ok
    end
  end

  defp validate_max_tool_calls!(opts) do
    case Keyword.fetch(opts, :max_tool_calls) do
      {:ok, n} when is_integer(n) and n > 0 -> :ok
      {:ok, nil} -> :ok
      {:ok, _} -> raise ArgumentError, "max_tool_calls must be a positive integer"
      :error -> :ok
    end
  end

  defp validate_journaling!(opts) do
    case Keyword.fetch(opts, :journaling) do
      {:ok, val} when is_boolean(val) -> :ok
      {:ok, _} -> raise ArgumentError, "journaling must be a boolean"
      :error -> :ok
    end
  end

  defp validate_self_tool_requires_signature!(opts) do
    tools = Keyword.get(opts, :tools, %{})
    signature = Keyword.get(opts, :signature)

    has_self = Enum.any?(tools, fn {_, v} -> v == :self end)

    if has_self and is_nil(signature) do
      raise ArgumentError,
            "agents with :self tools must have a signature"
    end

    :ok
  end
end
