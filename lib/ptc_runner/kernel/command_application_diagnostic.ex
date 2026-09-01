defmodule PtcRunner.Kernel.CommandApplicationDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.ComponentOverrideDiagnostic
  alias PtcRunner.Kernel.ContractSchemaDiagnostic
  alias PtcRunner.Kernel.LimitConfigurationDiagnostic
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.OptionalBudgetDiagnostic
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.SchemaPath
  alias PtcRunner.Kernel.SchemaViolation
  alias PtcRunner.Kernel.SchemaViolationDiagnostic
  alias PtcRunner.Kernel.ValueContractDiagnostic

  @spec project(:validate | :run | :doctor | :materialize, term()) :: CommandDiagnostic.t()
  def project(_command, reason) do
    {source_role, source_name, reason} = source_role(reason)
    {code, path_value} = projection(source_role, reason)

    source =
      if code == :contract_projection_limit_exceeded,
        do: nil,
        else: command_source(source_role, source_name)

    {source, path_value} = contract_diagnostic_parts(source, reason, path_value)

    CommandDiagnostic.new!(
      :application,
      code,
      [source: source, path: command_path(source_role, path_value)] ++ message_option(reason)
    )
  end

  # A rejected contract schema names its rule. A refused component override
  # names the descriptor field it broke. Every other reason keeps the catalog
  # literal, including a rule this boundary has no message for.
  defp message_option({:contract_schema_invalid, %{rule: rule}}) do
    case ContractSchemaDiagnostic.message(rule) do
      {:ok, message} -> [message: message]
      :error -> []
    end
  end

  defp message_option({:manifest_schema_invalid, %SchemaViolation{rule: rule}}) do
    case SchemaViolationDiagnostic.message(:application, rule) do
      {:ok, message} -> [message: message]
      :error -> []
    end
  end

  # The decoder already knows which limit was refused, what the manifest asked
  # for, and the ceiling that refused it. Saying so is what tells a reader how
  # far they overshot and which of the two documents to edit.
  defp message_option({:manifest_path, _path, reason}), do: message_option(reason)
  defp message_option({:component_override_path, _path, reason}), do: message_option(reason)

  defp message_option({:installed_limit_exceeded, name, requested, ceiling}) do
    case RuntimeLimitDiagnostic.installed_ceiling_message(name, requested, ceiling) do
      {:ok, message} -> [message: message]
      :error -> []
    end
  end

  defp message_option({:limit_unavailable, name, requested}) do
    case OptionalBudgetDiagnostic.unavailable_message(name, requested) do
      {:ok, message} -> [message: message]
      :error -> []
    end
  end

  defp message_option({:limit_configuration_invalid, bytes, required, payload}) do
    case LimitConfigurationDiagnostic.message(bytes, required, payload) do
      {:ok, message} -> [message: message]
      :error -> []
    end
  end

  defp message_option(reason) do
    case ComponentOverrideDiagnostic.message(reason) do
      {:ok, message} -> [message: message]
      :error -> []
    end
  end

  defp source_role({:source_role, role, reason})
       when role in [:external_input, :component_override],
       do: {role, nil, reason}

  defp source_role({:source_role, role, name, reason})
       when role in [:component, :input_contract, :result_contract] and is_binary(name),
       do: {role, name, reason}

  defp source_role({:source_role, {:phase_return_contract, _contract_name}, name, reason})
       when is_binary(name),
       do: {:phase_return_contract, name, reason}

  defp source_role(reason), do: {:application, nil, reason}

  defp command_source(role, nil)
       when role in [:application, :external_input, :component_override],
       do: CommandSource.fixed(role)

  defp command_source(role, name)
       when role in [:component, :input_contract, :result_contract, :phase_return_contract] do
    {:ok, source} = CommandSource.new(role, name)
    source
  end

  defp projection(:component_override, reason)
       when reason in [:document_limit_exceeded, :json_depth_exceeded, :json_node_limit_exceeded],
       do: {:document_limit_exceeded, nil}

  defp projection(
         :component_override,
         {:component_override_path, path, :invalid_override_descriptor}
       ),
       do: {:override_invalid, path}

  defp projection(:component_override, reason) do
    case ComponentOverrideDiagnostic.path(reason) do
      nil -> {:override_invalid, nil}
      path -> {:override_invalid, path}
    end
  end

  defp projection(role, {:manifest_path, path, reason}) do
    case projection(role, reason) do
      {code, suffix} when suffix in [nil, []] -> {code, path}
      {code, suffix} -> {code, path ++ suffix}
    end
  end

  defp projection(_role, :invalid_json), do: {:invalid_json, nil}
  defp projection(_role, :duplicate_json_key), do: {:duplicate_property, nil}
  defp projection(_role, :required_properties_missing), do: {:required_property_missing, []}

  defp projection(_role, {:required_property_missing, name}),
    do: {:required_property_missing, [{:property, name}]}

  defp projection(_role, :unknown_properties), do: {:schema_violation, []}

  defp projection(
         _role,
         {:manifest_schema_invalid, %SchemaViolation{rule: :required, path: path}}
       ),
       do: {:required_property_missing, path}

  defp projection(_role, {:manifest_schema_invalid, %SchemaViolation{path: path}}),
    do: {:schema_violation, path}

  defp projection(_role, {:schema_validation_unavailable, _cause}),
    do: {:schema_validation_unavailable, nil}

  defp projection(_role, :reference_missing), do: {:reference_missing, nil}
  defp projection(_role, :invalid_logical_name), do: {:reference_missing, nil}
  defp projection(:application, :not_found), do: {:application_not_found, nil}

  defp projection(:application, {:installed_limit_exceeded, name, requested, ceiling})
       when is_binary(name) and is_integer(requested) and is_integer(ceiling) and
              requested > ceiling,
       do: {:installed_limit_exceeded, nil}

  defp projection(:application, {:limit_unavailable, name, requested}) do
    case OptionalBudgetDiagnostic.unavailable_message(name, requested) do
      {:ok, _message} -> {:limit_unavailable, nil}
      :error -> {:schema_violation, nil}
    end
  end

  defp projection(
         :application,
         {:limit_configuration_invalid, bytes, required, payload}
       )
       when is_integer(bytes) and is_integer(required) and is_integer(payload),
       do: {:limit_configuration_invalid, nil}

  defp projection(_role, reason)
       when reason in [:document_limit_exceeded, :json_depth_exceeded, :json_node_limit_exceeded],
       do: {:document_limit_exceeded, nil}

  defp projection(role, :invalid_input) when role in [:application, :external_input],
    do: {:input_invalid, nil}

  defp projection(role, {:input_contract_failed, classification})
       when role in [:application, :external_input],
       do: {:input_contract_failed, classification}

  defp projection(_role, :invalid_contracts), do: {:contract_invalid, nil}

  defp projection(:application, :contract_projection_limit_exceeded),
    do: {:contract_projection_limit_exceeded, nil}

  defp projection(role, {:contract_schema_invalid, %{path: path}})
       when role in [:input_contract, :result_contract, :phase_return_contract],
       do: {:contract_invalid, path}

  defp projection(role, _reason)
       when role in [:input_contract, :result_contract, :phase_return_contract],
       do: {:contract_invalid, nil}

  defp projection(_role, :input_contract_failed), do: {:input_contract_failed, nil}

  defp projection(_role, :event_identity_conflict),
    do: {:event_identity_conflict, [{:property, "events"}]}

  defp projection(_role, reason)
       when reason in [
              :invalid_override_descriptor,
              :ambiguous_override_target,
              :override_component_not_selected
            ],
       do: {:override_invalid, nil}

  defp projection(_role, reason)
       when reason in [
              :invalid_application_source,
              :application_source_unavailable,
              :outside_application_source,
              :not_regular,
              :symlink_escape
            ],
       do: {:application_unavailable, nil}

  defp projection(_role, _reason), do: {:schema_violation, nil}

  defp command_path(_role, nil), do: nil
  defp command_path(_role, %CommandPath{} = path), do: path

  defp command_path(:component_override, segments) when is_list(segments) do
    {:ok, path} = CommandPath.component_override(segments)
    path
  end

  defp command_path(_role, segments) when is_list(segments) do
    safe_segments =
      segments
      |> Enum.map(fn
        {:property, name} -> name
        {:index, index} -> index
      end)
      |> SchemaPath.explained_prefix(Manifest.schema())

    {:ok, path} = CommandPath.manifest(safe_segments)
    path
  end

  defp contract_diagnostic_parts(
         source,
         {:input_contract_failed, classification},
         classification
       ),
       do: ValueContractDiagnostic.diagnostic_parts(source, classification)

  defp contract_diagnostic_parts(source, _reason, path), do: {source, path}
end
