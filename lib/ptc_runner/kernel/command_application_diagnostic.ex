defmodule PtcRunner.Kernel.CommandApplicationDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.SchemaPath

  @spec project(:validate | :run | :doctor, term()) :: CommandDiagnostic.t()
  def project(_command, reason) do
    {source_role, source_name, reason} = source_role(reason)
    {code, path_value} = projection(source_role, reason)

    source = command_source(source_role, source_name)

    CommandDiagnostic.new!(:application, code,
      source: bind_contract_source(source, reason),
      path: command_path(source_role, path_value)
    )
  end

  defp source_role({:source_role, role, reason})
       when role in [:external_input, :component_override],
       do: {role, nil, reason}

  defp source_role({:source_role, role, name, reason})
       when role in [:component, :input_contract, :result_contract] and is_binary(name),
       do: {role, name, reason}

  defp source_role(reason), do: {:application, nil, reason}

  defp command_source(role, nil)
       when role in [:application, :external_input, :component_override],
       do: CommandSource.fixed(role)

  defp command_source(role, name) when role in [:component, :input_contract, :result_contract] do
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

  defp projection(:component_override, _reason), do: {:override_invalid, nil}

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
  defp projection(_role, :reference_missing), do: {:reference_missing, nil}
  defp projection(_role, :invalid_logical_name), do: {:reference_missing, nil}
  defp projection(:application, :not_found), do: {:application_not_found, nil}

  defp projection(:application, {:installed_limit_exceeded, requested, ceiling})
       when is_integer(requested) and is_integer(ceiling) and requested > ceiling,
       do: {:installed_limit_exceeded, nil}

  defp projection(_role, reason)
       when reason in [:document_limit_exceeded, :json_depth_exceeded, :json_node_limit_exceeded],
       do: {:document_limit_exceeded, nil}

  defp projection(role, :invalid_input) when role in [:application, :external_input],
    do: {:input_invalid, nil}

  defp projection(role, {:input_contract_failed, classification})
       when role in [:application, :external_input],
       do: {:input_contract_failed, first_violation_path(classification)}

  defp projection(_role, :invalid_contracts), do: {:contract_invalid, nil}

  defp projection(role, _reason) when role in [:input_contract, :result_contract],
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

  defp first_violation_path(%{violations: violations}) when is_list(violations) do
    Enum.find_value(violations, fn
      %{path: %CommandPath{} = path} -> path
      _invalid -> nil
    end)
  end

  defp first_violation_path(_classification), do: nil

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

  defp bind_contract_source(source, {:input_contract_failed, %{contract_authority: authority}})
       when not is_nil(source) do
    {:ok, source} = CommandSource.with_contract(source, authority)
    source
  end

  defp bind_contract_source(source, _reason), do: source
end
