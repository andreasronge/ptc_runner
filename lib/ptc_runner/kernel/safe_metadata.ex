defmodule PtcRunner.Kernel.SafeMetadata do
  @moduledoc """
  Validates the closed, payload-free metadata vocabulary used by canonical events.

  Safe metadata is intentionally less expressive than general JSON. Every
  caller-supplied name/model/provider label is reduced to a one-way SHA-256
  fingerprint before it reaches a canonical event. Tags and workflow
  annotations use finite semantic vocabularies with no caller-defined keys or
  values. Prompts, credentials, generated source, and arbitrary application
  data therefore require private inspection.
  """

  @label_keys ~w(name model provider tags)
  @tag_values %{
    "environment" => ~w(development test staging production),
    "mode" => ~w(agent deterministic direct wrapper repl),
    "stage" => ~w(started planning executing validating completed failed),
    "suite" => ~w(unit integration e2e conformance privacy)
  }
  @identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,255}\z/
  @fingerprint ~r/\Asha256:[0-9a-f]{64}\z/
  @progress_stages ~w(started planning executing validating completed failed)
  @agent_action_kinds ~w(tool-call protocol-error provider-error)
  @failure_kinds ~w(
    invalid-agent-config
    invalid-input
    invalid-prompt
    invalid-transcript
    mission-unavailable
    transcript-limit
    turn-limit
    model-program-failed
    non-retryable-evaluation
    evaluation-unavailable
    llm-provider-error
    protocol-error
    provider-error
    capability-error
    capability-unavailable
    assertion-failed
    unknown-action
  )
  @llm_provider_failures ~w(
    authentication-failed payment-required rate-limited tool-calling-unsupported denied not-found timeout
    invalid-request unavailable transport-error internal domain-error invalid-result
  )

  @spec normalize_labels(term()) :: {:ok, map()} | {:error, :invalid_safe_metadata}
  @doc "Validates labels and fingerprints caller-defined identifier fields."
  def normalize_labels(labels) when is_map(labels) and not is_struct(labels) do
    keys = Map.keys(labels)

    if keys -- @label_keys == [] and valid_label_inputs?(labels) do
      normalized =
        labels
        |> Map.take(~w(name model provider))
        |> Map.new(fn {key, value} -> {key, fingerprint(value)} end)
        |> maybe_put_tags(Map.get(labels, "tags"))

      {:ok, normalized}
    else
      {:error, :invalid_safe_metadata}
    end
  end

  def normalize_labels(_labels), do: {:error, :invalid_safe_metadata}

  @spec labels?(term()) :: boolean()
  @doc "Returns whether a value is an already-normalized canonical-label map."
  def labels?(labels), do: match?({:ok, ^labels}, normalize_labels(labels))

  @spec annotation?(term(), term()) :: boolean()
  @doc """
  Returns whether an annotation belongs to the finite canonical vocabulary.

  `"progress"` carries exactly one enumerated `stage`. `"agent-action"` is
  the shipped agent loop's coarse per-turn record: exactly the keys `turn`
  (an integer from 0 through 127, matching the loop's maximum turn count)
  and `kind` (one of `tool-call`, `protocol-error`, or `provider-error`).
  It never carries detailed reasons, generated source, or model content —
  those stay in the agent's own history and, when enabled, in private
  inspection records.
  """
  def annotation?("progress", %{"stage" => stage} = data)
      when map_size(data) == 1 and stage in @progress_stages,
      do: true

  def annotation?("agent-action", %{"turn" => turn, "kind" => kind} = data)
      when map_size(data) == 2 and is_integer(turn) and turn >= 0 and turn <= 127 and
             kind in @agent_action_kinds,
      do: true

  def annotation?(_type, _data), do: false

  @spec failure_taxonomy(term()) :: map()
  @doc """
  Projects an explicit failure value to bounded, payload-free taxonomy.

  Known framework categories remain readable. An application-defined category
  is represented only by a stable fingerprint, so repeated failures can be
  grouped without putting the caller's value into a public error or trace.
  Values without a scalar `kind` field produce no public taxonomy.
  """
  def failure_taxonomy(value) when is_map(value) and not is_struct(value) do
    value
    |> fetch_failure_kind()
    |> normalize_failure_kind()
  end

  def failure_taxonomy(_value), do: %{}

  @doc "Projects an agent LLM failure to one closed, payload-free provider class."
  @spec llm_provider_failure(term()) :: map()
  def llm_provider_failure(value) when is_map(value) and not is_struct(value) do
    with {:ok, kind} <- fetch_named(value, "kind"),
         "llm-provider-error" <- normalize_name(kind),
         {:ok, reason} when is_map(reason) and not is_struct(reason) <-
           fetch_named(value, "reason"),
         {:ok, provider_reason} <- fetch_named(reason, "reason"),
         normalized when normalized in @llm_provider_failures <- normalize_name(provider_reason),
         {:ok, retryable?} when is_boolean(retryable?) <- fetch_named(reason, "retryable?") do
      %{
        llm_provider_failure: provider_failure_atom(normalized),
        llm_provider_retryable?: retryable?
      }
    else
      _not_a_known_llm_failure -> %{}
    end
  end

  def llm_provider_failure(_value), do: %{}

  @doc false
  @spec retain_llm_provider_failure_fields(term()) :: map()
  def retain_llm_provider_failure_fields(%{
        llm_provider_failure: failure,
        llm_provider_retryable?: retryable?
      })
      when failure in [
             :authentication_failed,
             :payment_required,
             :rate_limited,
             :tool_calling_unsupported,
             :denied,
             :not_found,
             :timeout,
             :invalid_request,
             :unavailable,
             :transport_error,
             :internal,
             :domain_error,
             :invalid_result
           ] and is_boolean(retryable?),
      do: %{llm_provider_failure: failure, llm_provider_retryable?: retryable?}

  def retain_llm_provider_failure_fields(_metadata), do: %{}

  @doc false
  @spec retain_failure_taxonomy(term()) :: map()
  def retain_failure_taxonomy(%{failure_kind: kind} = taxonomy)
      when map_size(taxonomy) == 1 and kind in @failure_kinds,
      do: taxonomy

  def retain_failure_taxonomy(%{failure_kind_fingerprint: fingerprint} = taxonomy)
      when map_size(taxonomy) == 1 and is_binary(fingerprint) do
    if fingerprint?(fingerprint), do: taxonomy, else: %{}
  end

  def retain_failure_taxonomy(_taxonomy), do: %{}

  @doc false
  @spec retain_failure_taxonomy_fields(term()) :: map()
  def retain_failure_taxonomy_fields(metadata) when is_map(metadata) do
    metadata
    |> Map.take([:failure_kind, :failure_kind_fingerprint])
    |> retain_failure_taxonomy()
  end

  def retain_failure_taxonomy_fields(_metadata), do: %{}

  @spec fingerprint(binary()) :: binary()
  @doc "Returns the canonical non-reversible fingerprint for one bounded identifier."
  def fingerprint(value) when is_binary(value) do
    if fingerprint?(value) do
      value
    else
      "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
    end
  end

  defp fetch_failure_kind(value) do
    Enum.find_value(value, fn {key, kind} ->
      if metadata_name(key) == "kind", do: kind
    end)
  end

  defp fetch_named(value, name) do
    case Enum.find(value, fn {key, _field} -> metadata_name(key) == name end) do
      {_key, field} -> {:ok, field}
      nil -> :error
    end
  end

  defp normalize_name(%PtcRunner.Lisp.Keyword{name: name}), do: normalize_name(name)

  defp normalize_name(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_name()

  defp normalize_name(value) when is_binary(value) and byte_size(value) in 1..64 do
    if String.valid?(value), do: String.replace(value, "_", "-"), else: nil
  end

  defp normalize_name(_value), do: nil

  defp provider_failure_atom("authentication-failed"), do: :authentication_failed
  defp provider_failure_atom("payment-required"), do: :payment_required
  defp provider_failure_atom("rate-limited"), do: :rate_limited
  defp provider_failure_atom("tool-calling-unsupported"), do: :tool_calling_unsupported
  defp provider_failure_atom("denied"), do: :denied
  defp provider_failure_atom("not-found"), do: :not_found
  defp provider_failure_atom("timeout"), do: :timeout
  defp provider_failure_atom("invalid-request"), do: :invalid_request
  defp provider_failure_atom("unavailable"), do: :unavailable
  defp provider_failure_atom("transport-error"), do: :transport_error
  defp provider_failure_atom("internal"), do: :internal
  defp provider_failure_atom("domain-error"), do: :domain_error
  defp provider_failure_atom("invalid-result"), do: :invalid_result

  defp metadata_name(%PtcRunner.Lisp.Keyword{name: name}), do: name
  defp metadata_name(value) when is_atom(value), do: Atom.to_string(value)
  defp metadata_name(value) when is_binary(value), do: value
  defp metadata_name(_value), do: nil

  defp normalize_failure_kind(%PtcRunner.Lisp.Keyword{name: kind}),
    do: normalize_failure_kind(kind)

  defp normalize_failure_kind(kind) when is_atom(kind),
    do: kind |> Atom.to_string() |> normalize_failure_kind()

  defp normalize_failure_kind(kind)
       when is_binary(kind) and byte_size(kind) in 1..256 do
    if String.valid?(kind) do
      normalized = String.replace(kind, "_", "-")

      if normalized in @failure_kinds,
        do: %{failure_kind: normalized},
        else: %{failure_kind_fingerprint: fingerprint("failure-kind:" <> kind)}
    else
      %{}
    end
  end

  defp normalize_failure_kind(_kind), do: %{}

  defp valid_label_inputs?(labels) do
    Enum.all?(Map.take(labels, ~w(name model provider)), fn {_key, value} ->
      identifier?(value) or fingerprint?(value)
    end) and tags_input?(Map.get(labels, "tags", %{}))
  end

  defp tags_input?(tags) when is_map(tags) and not is_struct(tags) and map_size(tags) <= 32,
    do:
      Enum.all?(tags, fn {key, value} ->
        case @tag_values do
          %{^key => allowed_values} -> value in allowed_values
          _unknown -> false
        end
      end)

  defp tags_input?(_tags), do: false

  defp maybe_put_tags(labels, nil), do: labels

  defp maybe_put_tags(labels, tags) do
    Map.put(labels, "tags", tags)
  end

  defp identifier?(value), do: is_binary(value) and String.valid?(value) and value =~ @identifier
  defp fingerprint?(value), do: is_binary(value) and value =~ @fingerprint
end
