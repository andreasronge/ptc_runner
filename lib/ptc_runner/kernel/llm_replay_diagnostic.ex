defmodule PtcRunner.Kernel.LLMReplayDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Lisp.Keyword, as: LispKeyword

  @prefix "no replay fixture matches this request (request_hash: "
  @suffix ")"
  @hash_pattern "sha256:[0-9a-f]{64}"
  @hash_regex ~r/\Asha256:[0-9a-f]{64}\z/
  @message_regex ~r/\Ano replay fixture matches this request \(request_hash: (sha256:[0-9a-f]{64})\)\z/
  @maximum_message_bytes byte_size(@prefix) + 71 + byte_size(@suffix)

  @doc false
  @spec message(term()) :: {:ok, binary()} | :error
  def message(request_hash) when is_binary(request_hash) do
    if request_hash =~ @hash_regex,
      do: {:ok, @prefix <> request_hash <> @suffix},
      else: :error
  end

  def message(_request_hash), do: :error

  @doc false
  @spec valid_request_hash?(term()) :: boolean()
  def valid_request_hash?(request_hash), do: match?({:ok, _message}, message(request_hash))

  @doc false
  @spec request_hash(term()) :: {:ok, binary()} | :error
  def request_hash(message) when is_binary(message) do
    case Regex.run(@message_regex, message, capture: :all_but_first) do
      [request_hash] -> {:ok, request_hash}
      _invalid -> :error
    end
  end

  def request_hash(_message), do: :error

  @doc false
  @spec failure_metadata(term()) :: map()
  def failure_metadata(value) when is_map(value) and not is_struct(value) do
    case replay_provider_error(value) do
      {:ok, request_hash} ->
        %{replay_request_hash: request_hash}

      :error ->
        wrapped_failure_metadata(value)
    end
  end

  def failure_metadata(_value), do: %{}

  defp wrapped_failure_metadata(value) do
    with {:ok, kind} <- fetch_named(value, "kind"),
         true <- named_value?(kind, "llm_provider_error"),
         {:ok, provider_error} <- wrapped_provider_error(value),
         {:ok, request_hash} <- replay_provider_error(provider_error) do
      %{replay_request_hash: request_hash}
    else
      _invalid -> %{}
    end
  end

  defp wrapped_provider_error(value) do
    case fetch_named(value, "reason") do
      {:ok, provider_error} -> {:ok, provider_error}
      :error -> fetch_named(value, "provider_response")
    end
  end

  defp replay_provider_error(provider_error)
       when is_map(provider_error) and not is_struct(provider_error) do
    with {:ok, status} <- fetch_named(provider_error, "status"),
         true <- named_value?(status, "error"),
         {:ok, provider_kind} <- fetch_named(provider_error, "kind"),
         true <- named_value?(provider_kind, "provider_error"),
         {:ok, reason} <- fetch_named(provider_error, "reason"),
         true <- named_value?(reason, "not_found"),
         {:ok, false} <- fetch_named(provider_error, "retryable?"),
         {:ok, details} <- fetch_named(provider_error, "details"),
         {:ok, request_hash} <- request_hash(details) do
      {:ok, request_hash}
    else
      _invalid -> :error
    end
  end

  defp replay_provider_error(_provider_error), do: :error

  @doc false
  @spec retain_candidate_metadata(term()) :: map()
  def retain_candidate_metadata(%{replay_request_hash: request_hash}) do
    if valid_request_hash?(request_hash), do: %{replay_request_hash: request_hash}, else: %{}
  end

  def retain_candidate_metadata(_metadata), do: %{}

  @doc false
  @spec retain_parallel_failure_metadata(term()) :: map()
  def retain_parallel_failure_metadata(metadata) when is_map(metadata) do
    metadata
    |> SafeMetadata.retain_failure_taxonomy_fields()
    |> Map.merge(retain_candidate_metadata(metadata))
    |> Map.merge(SafeMetadata.retain_llm_provider_failure_fields(metadata))
  end

  def retain_parallel_failure_metadata(_metadata), do: %{}

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message), do: match?({:ok, _request_hash}, request_hash(message))

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    %{
      "oneOf" => [
        %{"const" => fallback},
        %{
          "type" => "string",
          "minLength" => @maximum_message_bytes,
          "maxLength" => @maximum_message_bytes,
          "pattern" =>
            "^no replay fixture matches this request \\(request_hash: #{@hash_pattern}\\)$(?![\\s\\S])"
        }
      ]
    }
  end

  defp fetch_named(map, expected) do
    Enum.find_value(map, :error, fn {key, value} ->
      if normalized_name(key) == expected, do: {:ok, value}
    end)
  end

  defp named_value?(value, expected), do: normalized_name(value) == expected

  defp normalized_name(%LispKeyword{name: name}), do: normalize(name)
  defp normalized_name(value) when is_atom(value), do: value |> Atom.to_string() |> normalize()
  defp normalized_name(value) when is_binary(value), do: normalize(value)
  defp normalized_name(_value), do: nil

  defp normalize(value), do: String.replace(value, "-", "_")
end
