defmodule PtcRunnerMcp.AgenticConfig do
  @moduledoc """
  Boot-time configuration for experimental agentic aggregator mode.

  Agentic mode is opt-in. It exposes `ptc_task` only when ordinary
  aggregator mode is active, and it never changes `ptc_lisp_execute`.
  """

  @defaults %{
    enabled: false,
    model: "gemini-flash-lite",
    task_timeout_ms: 45_000,
    planner_timeout_ms: 15_000,
    max_output_tokens: 1_200,
    max_result_bytes: 4_096,
    include_program: true,
    trace_prompts: false,
    max_turns: 1,
    retry_turns: 0,
    allow_writes: false,
    subagent_config_path: nil,
    capability_summary_max_bytes: 800,
    capability_summary_path: nil,
    capability_summary: nil,
    system_prompt: %{prefix: nil, suffix: nil}
  }

  @allowed_subagent_keys ~w(max_turns retry_turns system_prompt)
  @allowed_system_prompt_keys ~w(prefix suffix)
  @reserved_subagent_keys ~w(
    tools signature output ptc_transport completion_mode trace_context
  )
  @prompt_slot_max_bytes 4_096

  @type t :: %{
          enabled: boolean(),
          model: String.t(),
          task_timeout_ms: pos_integer(),
          planner_timeout_ms: pos_integer(),
          max_output_tokens: pos_integer(),
          max_result_bytes: pos_integer(),
          include_program: boolean(),
          trace_prompts: boolean(),
          max_turns: pos_integer(),
          retry_turns: non_neg_integer(),
          allow_writes: boolean(),
          subagent_config_path: String.t() | nil,
          capability_summary_max_bytes: pos_integer(),
          capability_summary_path: String.t() | nil,
          capability_summary: String.t() | nil,
          system_prompt: %{prefix: String.t() | nil, suffix: String.t() | nil}
        }

  @spec defaults() :: t()
  def defaults, do: @defaults

  @spec set(map()) :: :ok
  def set(overrides) when is_map(overrides) do
    merged = Map.merge(defaults(), Map.take(overrides, Map.keys(defaults())))
    :persistent_term.put({__MODULE__, :config}, merged)
    :ok
  end

  @spec get() :: t()
  def get do
    :persistent_term.get({__MODULE__, :config}, defaults())
  end

  @spec enabled?() :: boolean()
  def enabled?, do: get().enabled == true

  @doc false
  @spec load_subagent_config!(String.t() | nil) :: map()
  def load_subagent_config!(nil), do: %{}
  def load_subagent_config!(""), do: %{}

  def load_subagent_config!(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, config} <- validate_subagent_config(decoded, path) do
      config
    else
      {:error, %Jason.DecodeError{} = reason} ->
        raise_config!(
          "agentic_subagent_config: malformed JSON in #{path}: #{Exception.message(reason)}"
        )

      {:error, reason} when is_atom(reason) ->
        raise_config!(
          "agentic_subagent_config: cannot read #{path}: #{:file.format_error(reason)}"
        )

      {:error, message} when is_binary(message) ->
        raise_config!(message)
    end
  end

  @doc false
  @spec load_capability_summary!(String.t() | nil, pos_integer()) :: String.t() | nil
  def load_capability_summary!(nil, _max_bytes), do: nil
  def load_capability_summary!("", _max_bytes), do: nil

  def load_capability_summary!(path, max_bytes)
      when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    case File.read(path) do
      {:ok, body} ->
        bytes = byte_size(body)

        if bytes > max_bytes do
          raise_config!(
            "agentic_capability_summary: #{path} is #{bytes} bytes, exceeding configured cap #{max_bytes}"
          )
        else
          body
        end

      {:error, reason} ->
        raise_config!(
          "agentic_capability_summary: cannot read #{path}: #{:file.format_error(reason)}"
        )
    end
  end

  @doc false
  @spec allowed_subagent_keys() :: [String.t()]
  def allowed_subagent_keys, do: @allowed_subagent_keys

  @doc false
  @spec reserved_subagent_keys() :: [String.t()]
  def reserved_subagent_keys, do: @reserved_subagent_keys

  @doc false
  @spec log_boot(t(), map()) :: :ok
  def log_boot(%{enabled: true} = config, source_keys) when is_map(source_keys) do
    PtcRunnerMcp.Log.log(:info, "agentic_config", %{
      subagent_config: config.subagent_config_path,
      applied: applied_report(config, source_keys),
      defaulted: defaulted_report(source_keys),
      capability_summary: capability_summary_report(config.capability_summary)
    })
  end

  def log_boot(_config, _source_keys), do: :ok

  defp validate_subagent_config(decoded, path) when is_map(decoded) and not is_struct(decoded) do
    case reject_top_level_keys(decoded, path) do
      :ok -> normalize_subagent_config(decoded, path)
      {:error, message} -> {:error, message}
    end
  end

  defp validate_subagent_config(_decoded, path) do
    {:error, "agentic_subagent_config: #{path} must contain a JSON object"}
  end

  defp reject_top_level_keys(decoded, path) do
    keys = Map.keys(decoded)
    reserved = Enum.filter(keys, &reserved_key?/1)
    unknown = keys -- (@allowed_subagent_keys -- reserved)

    cond do
      reserved != [] ->
        {:error,
         key_error(path, "reserved", reserved) <>
           " Reserved keys are MCP-controlled and cannot be set here."}

      unknown != [] ->
        {:error, key_error(path, "unknown", unknown)}

      true ->
        :ok
    end
  end

  defp reserved_key?("_" <> _), do: true
  defp reserved_key?(key), do: key in @reserved_subagent_keys

  defp key_error(path, kind, keys) do
    "agentic_subagent_config: #{path} contains #{kind} key(s): #{Enum.join(Enum.sort(keys), ", ")}. " <>
      "Allowed keys: #{Enum.join(@allowed_subagent_keys, ", ")}. " <>
      "Allowed system_prompt keys: #{Enum.join(@allowed_system_prompt_keys, ", ")}."
  end

  defp normalize_subagent_config(decoded, path) do
    Enum.reduce_while(decoded, {:ok, %{}}, fn
      {"max_turns", value}, {:ok, acc} ->
        put_pos_int(acc, :max_turns, value, "max_turns", path)

      {"retry_turns", value}, {:ok, acc} ->
        put_non_neg_int(acc, :retry_turns, value, "retry_turns", path)

      {"system_prompt", value}, {:ok, acc} ->
        case normalize_system_prompt(value, path) do
          {:ok, system_prompt} -> {:cont, {:ok, Map.put(acc, :system_prompt, system_prompt)}}
          {:error, message} -> {:halt, {:error, message}}
        end
    end)
  end

  defp normalize_system_prompt(nil, _path), do: {:ok, %{prefix: nil, suffix: nil}}

  defp normalize_system_prompt(value, path) when is_map(value) and not is_struct(value) do
    keys = Map.keys(value)
    unknown = keys -- @allowed_system_prompt_keys

    if unknown != [] do
      {:error,
       "agentic_subagent_config: #{path} contains unknown system_prompt key(s): #{Enum.join(Enum.sort(unknown), ", ")}. " <>
         "Allowed system_prompt keys: #{Enum.join(@allowed_system_prompt_keys, ", ")}."}
    else
      with {:ok, prefix} <- prompt_slot(value, "prefix", path),
           {:ok, suffix} <- prompt_slot(value, "suffix", path) do
        {:ok, present_prompt_slots(value, prefix, suffix)}
      end
    end
  end

  defp normalize_system_prompt(_value, path) do
    {:error, "agentic_subagent_config: #{path} key system_prompt must be an object or null"}
  end

  defp prompt_slot(map, key, path) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        bytes = byte_size(value)

        if bytes <= @prompt_slot_max_bytes do
          {:ok, value}
        else
          {:error,
           "agentic_subagent_config: #{path} system_prompt.#{key} is #{bytes} bytes, exceeding #{@prompt_slot_max_bytes}"}
        end

      _value ->
        {:error, "agentic_subagent_config: #{path} system_prompt.#{key} must be a string or null"}
    end
  end

  defp present_prompt_slots(value, prefix, suffix) do
    %{}
    |> maybe_put_prompt_slot(value, "prefix", :prefix, prefix)
    |> maybe_put_prompt_slot(value, "suffix", :suffix, suffix)
  end

  defp maybe_put_prompt_slot(acc, value, source_key, out_key, out_value) do
    if Map.has_key?(value, source_key), do: Map.put(acc, out_key, out_value), else: acc
  end

  defp put_pos_int(acc, key, value, _source_key, _path) when is_integer(value) and value > 0,
    do: {:cont, {:ok, Map.put(acc, key, value)}}

  defp put_pos_int(_acc, _key, _value, source_key, path),
    do:
      {:halt,
       {:error, "agentic_subagent_config: #{path} key #{source_key} must be a positive integer"}}

  defp put_non_neg_int(acc, key, value, _source_key, _path)
       when is_integer(value) and value >= 0,
       do: {:cont, {:ok, Map.put(acc, key, value)}}

  defp put_non_neg_int(_acc, _key, _value, source_key, path),
    do:
      {:halt,
       {:error,
        "agentic_subagent_config: #{path} key #{source_key} must be a non-negative integer"}}

  defp applied_report(config, source_keys) do
    %{
      max_turns: source_value(config.max_turns, source_keys[:max_turns]),
      retry_turns: source_value(config.retry_turns, source_keys[:retry_turns]),
      allow_writes: source_value(config.allow_writes, source_keys[:allow_writes]),
      system_prompt_prefix_bytes:
        source_value(
          prompt_bytes(config.system_prompt.prefix),
          source_keys[:system_prompt_prefix]
        ),
      system_prompt_suffix_bytes:
        source_value(
          prompt_bytes(config.system_prompt.suffix),
          source_keys[:system_prompt_suffix]
        )
    }
  end

  defp defaulted_report(source_keys) do
    defaults = defaults()

    %{
      max_turns: defaulted_value(defaults.max_turns, source_keys[:max_turns]),
      retry_turns: defaulted_value(defaults.retry_turns, source_keys[:retry_turns]),
      allow_writes: defaulted_value(defaults.allow_writes, source_keys[:allow_writes]),
      system_prompt_prefix_bytes: defaulted_value(0, source_keys[:system_prompt_prefix]),
      system_prompt_suffix_bytes: defaulted_value(0, source_keys[:system_prompt_suffix])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp source_value(value, nil), do: value
  defp source_value(value, source), do: %{value: value, source: source}

  defp defaulted_value(value, nil), do: value
  defp defaulted_value(_value, _source), do: nil

  defp prompt_bytes(nil), do: 0
  defp prompt_bytes(value), do: byte_size(value)

  defp capability_summary_report(nil), do: %{bytes: 0, hash: nil}

  defp capability_summary_report(summary) when is_binary(summary) do
    %{
      bytes: byte_size(summary),
      hash: :crypto.hash(:sha256, summary) |> Base.encode16(case: :lower)
    }
  end

  defp raise_config!(message), do: raise(ArgumentError, message)
end
