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

  # Validate that required fields are present
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
    validate_mission_timeout!(opts)
    validate_signature!(opts)
    validate_llm_retry!(opts)
    validate_tool_catalog!(opts)
    validate_prompt_limit!(opts)
    validate_memory_limit!(opts)
    validate_max_depth!(opts)
    validate_turn_budget!(opts)
    validate_prompt_placeholders!(opts)
    validate_description!(opts)
    validate_field_descriptions!(opts)
    validate_format_options!(opts)
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

  defp validate_mission_timeout!(opts) do
    case Keyword.fetch(opts, :mission_timeout) do
      {:ok, timeout} when is_integer(timeout) and timeout > 0 -> :ok
      {:ok, nil} -> :ok
      {:ok, _} -> raise ArgumentError, "mission_timeout must be a positive integer or nil"
      :error -> :ok
    end
  end

  defp validate_signature!(opts) do
    case Keyword.fetch(opts, :signature) do
      {:ok, sig} when is_binary(sig) -> :ok
      {:ok, _} -> raise ArgumentError, "signature must be a string"
      :error -> :ok
    end
  end

  defp validate_llm_retry!(opts) do
    case Keyword.fetch(opts, :llm_retry) do
      {:ok, retry} when is_map(retry) -> :ok
      {:ok, _} -> raise ArgumentError, "llm_retry must be a map"
      :error -> :ok
    end
  end

  defp validate_tool_catalog!(opts) do
    case Keyword.fetch(opts, :tool_catalog) do
      {:ok, catalog} when is_map(catalog) -> :ok
      {:ok, _} -> raise ArgumentError, "tool_catalog must be a map"
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
    alias PtcRunner.SubAgent.Template

    with {:ok, prompt} <- Keyword.fetch(opts, :prompt),
         {:ok, signature} <- Keyword.fetch(opts, :signature) do
      placeholders = Template.extract_placeholder_names(prompt)
      signature_params = Template.extract_signature_params(signature)

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

  defp validate_format_options!(opts) do
    case Keyword.fetch(opts, :format_options) do
      {:ok, fo} when is_list(fo) -> :ok
      {:ok, _} -> raise ArgumentError, "format_options must be a keyword list"
      :error -> :ok
    end
  end
end
