defmodule PtcRunner.Kernel.SafeMetadata do
  @moduledoc """
  Validates the closed, payload-free metadata vocabulary used by canonical events.

  Safe metadata is intentionally less expressive than general JSON. Every
  caller-supplied name/model/provider label is reduced to a one-way SHA-256
  fingerprint before it reaches a canonical event. Tags and workflow
  annotations use finite semantic vocabularies: types and keys are closed,
  and enumerated values are closed. A phased workflow annotation may also
  carry `mission`, a bounded identifier rather than a free string. Prompts,
  credentials, generated source, and arbitrary application data therefore
  require private inspection.
  """

  alias PtcRunner.Kernel.LLMFailureCatalog

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
  @agent_action_kinds ~w(tool-call protocol-error provider-error max-calls model-output-truncated)
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
  @llm_provider_failures LLMFailureCatalog.authenticated_kebabs()
  @capability_rejection_kinds [
    :capability_denied,
    :capability_unavailable,
    :event_sink_error,
    :inspection_sink_error,
    :invalid_annotation,
    :invalid_result,
    :limit_exceeded,
    :protocol_error,
    :provider_error,
    :result_exceeded,
    :timeout
  ]
  @capability_rejection_reasons [
    :ambiguous_arguments,
    :argument_exceeded,
    :authentication_failed,
    :capability_absent,
    :capability_quota,
    :denied,
    :domain_error,
    :event_sink_error,
    :exception,
    :exit,
    :input_validation_unavailable,
    :inspection_sink_error,
    :internal,
    :invalid_arguments,
    :invalid_agent_config_failure,
    :invalid_agent_protocol_error,
    :invalid_capability_description_request,
    :invalid_capability_list_request,
    :invalid_kernel_check_source_request,
    :invalid_kernel_eval_request,
    :invalid_llm_provider_failure,
    :invalid_mission_inventory_request,
    :invalid_mission_model_context_request,
    :invalid_model_alias,
    :invalid_provider_return,
    :invalid_request,
    :invalid_result,
    :invalid_result_contract_failure,
    :invalid_result_contract_request,
    :invalid_runtime_limit_failure,
    :invalid_runtime_remaining_request,
    :invalid_runtime_usage_request,
    :invalid_workflow_annotation,
    :live_provider_tasks,
    :llm_cost_microusd,
    :llm_total_tokens,
    :model_alias_required,
    :not_found,
    :output_schema_mismatch,
    :output_validation_unavailable,
    :payment_required,
    :protocol_errors,
    :provider_exit,
    :provider_heap_exceeded,
    :provider_result_limit,
    :provider_timeout,
    :llm_request_timeout,
    :llm_output_authorization_invalid,
    :rate_limited,
    :reservation_attestation_unavailable,
    :reservation_bound_exceeded,
    :reservation_held,
    :resolver_unavailable,
    :run_closed,
    :run_deadline,
    :stale_evaluation,
    :structured_output_unsupported,
    :throw,
    :timeout,
    :tool_calling_unsupported,
    :transport_error,
    :unavailable,
    :unknown_mission,
    :unknown_model_alias,
    :usage_unavailable
  ]

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
  and `kind` (one of `tool-call`, `protocol-error`, `provider-error`, or
  `max-calls`, or `model-output-truncated`).
  A phased agent run adds exactly `phase` (0 through 7), `phase_turn`
  (0 through 127), and `mission` (the phase's mission name) — all three or
  none, so a partial shape stays out of the vocabulary. It never carries
  detailed reasons, generated source, or model content — those stay in the
  agent's own history and, when enabled, in private inspection records.
  """
  def annotation?("progress", %{"stage" => stage} = data)
      when map_size(data) == 1 and stage in @progress_stages,
      do: true

  def annotation?("agent-action", %{"turn" => turn, "kind" => kind} = data)
      when map_size(data) == 2 and is_integer(turn) and turn >= 0 and turn <= 127 and
             kind in @agent_action_kinds,
      do: true

  def annotation?(
        "agent-action",
        %{
          "turn" => turn,
          "kind" => kind,
          "phase" => phase,
          "phase_turn" => phase_turn,
          "mission" => mission
        } = data
      )
      when map_size(data) == 5 and is_integer(turn) and turn >= 0 and turn <= 127 and
             kind in @agent_action_kinds and is_integer(phase) and phase >= 0 and phase <= 7 and
             is_integer(phase_turn) and phase_turn >= 0 and phase_turn <= 127 and
             is_binary(mission) do
    mission =~ ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  end

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

  @spec rejection_class(term()) :: map()
  @doc """
  Projects a Lisp capability error envelope to a payload-free rejection class.

  Known Kernel `kind` and `reason` atoms remain readable on canonical
  `capability-stopped` events. An unrecognized atom is retained only as a
  one-way fingerprint so a missed Kernel class still groups without putting
  the atom name on the public trace. Non-atoms, details, and messages produce
  no public fields.
  """
  def rejection_class(%{status: :error} = result) when is_map(result) and not is_struct(result) do
    %{}
    |> put_rejection_atom(result, :kind, @capability_rejection_kinds, "capability-kind:")
    |> put_rejection_atom(result, :reason, @capability_rejection_reasons, "capability-reason:")
  end

  def rejection_class(_result), do: %{}

  @doc """
  Builds the public `usage.capability_refusals` key for one error envelope.

  The key is `"<environment>/<kind>/<reason>"`. A known atom stays readable, an
  unrecognized atom is the same one-way fingerprint `rejection_class/1` uses,
  and a missing or non-atom field is `unknown`. Distinct keys are capped by
  `capability_refusal_map_limit/0`; further classes increment `$overflow`.
  """
  @spec capability_refusal_key(:workflow | :mission, map()) :: binary()
  def capability_refusal_key(environment, result)
      when environment in [:workflow, :mission] and is_map(result) and not is_struct(result) do
    class = rejection_class(result)

    Enum.join(
      [
        Atom.to_string(environment),
        refusal_key_segment(class, :kind, :kind_fingerprint),
        refusal_key_segment(class, :reason, :reason_fingerprint)
      ],
      "/"
    )
  end

  @doc """
  Maximum distinct closed-class keys retained in `usage.capability_refusals`.

  Terminal usage admission reserves this many fingerprint-length keys plus
  `$overflow`. Two named classes is the largest such map that still admits an
  empty environment at the catalog `event_payload_bytes` floor. Further classes
  increment `$overflow`.
  """
  @spec capability_refusal_map_limit() :: 2
  def capability_refusal_map_limit, do: 2

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
        llm_provider_failure: LLMFailureCatalog.consume_kind(normalized),
        llm_provider_retryable?: retryable?
      }
    else
      _not_a_known_llm_failure -> %{}
    end
  end

  def llm_provider_failure(_value), do: %{}

  @alias ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @capability_name ~r|\A[a-z][a-z0-9._/-]{0,127}\z|
  @public_quota_limits [
    :workflow_capability_calls,
    :workflow_capability_calls_per_name,
    :mission_capability_calls,
    :mission_capability_calls_per_name
  ]
  @quota_limit_names %{
    "max-calls" => :max_calls,
    "workflow-capability-calls" => :workflow_capability_calls,
    "workflow-capability-calls-per-name" => :workflow_capability_calls_per_name,
    "mission-capability-calls" => :mission_capability_calls,
    "mission-capability-calls-per-name" => :mission_capability_calls_per_name
  }

  @doc false
  @spec named_quota_refusal(term()) :: {:ok, map()} | :error
  def named_quota_refusal(value) when is_map(value) and not is_struct(value) do
    with {:ok, status} <- fetch_named(value, "status"),
         true <- status in [:error, "error"],
         {:ok, kind} <- fetch_named(value, "kind"),
         "limit-exceeded" <- normalize_name(kind),
         {:ok, reason} <- fetch_named(value, "reason"),
         "capability-quota" <- normalize_name(reason),
         {:ok, details} when is_map(details) and not is_struct(details) <-
           fetch_named(value, "details"),
         {:ok, limit} <- fetch_named(details, "limit"),
         {:ok, limit_atom} <- quota_limit_atom(normalize_name(limit)),
         {:ok, limit_value} when is_integer(limit_value) and limit_value > 0 <-
           fetch_named(details, "limit_value"),
         {:ok, identity} <- quota_identity_fields(limit_atom, details) do
      {:ok, Map.merge(%{limit: limit_atom, limit_value: limit_value}, identity)}
    else
      _not_a_named_quota_refusal -> :error
    end
  end

  def named_quota_refusal(_value), do: :error

  @doc false
  @spec max_calls_refusal(term()) ::
          {:ok, %{limit: :max_calls, alias: binary(), limit_value: pos_integer()}} | :error
  def max_calls_refusal(value) do
    case named_quota_refusal(value) do
      {:ok, %{limit: :max_calls} = details} -> {:ok, details}
      _not_max_calls -> :error
    end
  end

  @doc false
  @spec max_calls_refusal_fields(term()) :: map()
  def max_calls_refusal_fields(value), do: named_quota_refusal_fields(value)

  @doc false
  @spec named_quota_refusal_fields(term()) :: map()
  def named_quota_refusal_fields(value) do
    case named_quota_refusal(value) do
      {:ok, details} -> details
      :error -> %{}
    end
  end

  @doc false
  @spec retain_max_calls_refusal_fields(term()) :: map()
  def retain_max_calls_refusal_fields(metadata), do: retain_named_quota_refusal_fields(metadata)

  @doc false
  @spec retain_named_quota_refusal_fields(term()) :: map()
  def retain_named_quota_refusal_fields(%{
        limit: :max_calls,
        alias: alias_name,
        limit_value: limit
      })
      when is_binary(alias_name) and is_integer(limit) and limit > 0 do
    if alias_name =~ @alias,
      do: %{limit: :max_calls, alias: alias_name, limit_value: limit},
      else: %{}
  end

  def retain_named_quota_refusal_fields(%{
        limit: limit,
        name: name,
        limit_value: value
      })
      when limit in @public_quota_limits and is_binary(name) and is_integer(value) and value > 0 do
    if name =~ @capability_name,
      do: %{limit: limit, name: name, limit_value: value},
      else: %{}
  end

  def retain_named_quota_refusal_fields(_metadata), do: %{}

  @budget_limits [:llm_total_tokens, :llm_cost_microusd]
  @budget_limit_names %{
    "llm-total-tokens" => :llm_total_tokens,
    "llm-cost-microusd" => :llm_cost_microusd
  }

  @doc false
  @spec budget_refusal(term()) :: {:ok, map()} | :error
  def budget_refusal(value) when is_map(value) and not is_struct(value) do
    with {:ok, status} <- fetch_named(value, "status"),
         true <- status in [:error, "error"],
         {:ok, kind} <- fetch_named(value, "kind"),
         "limit-exceeded" <- normalize_name(kind),
         {:ok, reason} <- fetch_named(value, "reason"),
         {:ok, reason_atom} <- budget_limit_atom(normalize_name(reason)),
         {:ok, details} when is_map(details) and not is_struct(details) <-
           fetch_named(value, "details"),
         {:ok, limit} <- fetch_named(details, "limit"),
         {:ok, limit_atom} <- budget_limit_atom(normalize_name(limit)),
         true <- limit_atom == reason_atom,
         {:ok, limit_value} when is_integer(limit_value) and limit_value > 0 <-
           fetch_named(details, "limit_value"),
         {:ok, requested} when is_integer(requested) and requested >= 0 <-
           fetch_named(details, "requested"),
         {:ok, remaining} when is_integer(remaining) and remaining >= 0 <-
           fetch_named(details, "remaining"),
         true <- remaining <= limit_value,
         true <- requested > remaining do
      {:ok,
       %{
         limit: limit_atom,
         limit_value: limit_value,
         requested: requested,
         remaining: remaining
       }}
    else
      _not_a_budget_refusal -> :error
    end
  end

  def budget_refusal(_value), do: :error

  @doc false
  @spec budget_refusal_fields(term()) :: map()
  def budget_refusal_fields(value) do
    case budget_refusal(value) do
      {:ok, details} -> details
      :error -> %{}
    end
  end

  @doc false
  @spec retain_budget_refusal_fields(term()) :: map()
  def retain_budget_refusal_fields(%{
        limit: limit,
        limit_value: limit_value,
        requested: requested,
        remaining: remaining
      })
      when limit in @budget_limits and is_integer(limit_value) and limit_value > 0 and
             is_integer(requested) and is_integer(remaining) and remaining >= 0 and
             remaining <= limit_value and requested > remaining do
    %{limit: limit, limit_value: limit_value, requested: requested, remaining: remaining}
  end

  def retain_budget_refusal_fields(_metadata), do: %{}

  defp quota_limit_atom(name) when is_binary(name), do: Map.fetch(@quota_limit_names, name)
  defp quota_limit_atom(_name), do: :error

  defp budget_limit_atom(name) when is_binary(name), do: Map.fetch(@budget_limit_names, name)
  defp budget_limit_atom(_name), do: :error

  defp quota_identity_fields(:max_calls, details) do
    with {:ok, alias_name} when is_binary(alias_name) <- fetch_named(details, "alias"),
         true <- alias_name =~ @alias do
      {:ok, %{alias: alias_name}}
    else
      _invalid_alias -> :error
    end
  end

  defp quota_identity_fields(limit, details) when limit in @public_quota_limits do
    with {:ok, name} when is_binary(name) <- fetch_named(details, "name"),
         true <- name =~ @capability_name do
      {:ok, %{name: name}}
    else
      _invalid_name -> :error
    end
  end

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
             :invalid_result,
             :usage_unavailable,
             :reservation_bound_exceeded
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

  defp put_rejection_atom(class, result, key, allowed, prefix) do
    case result do
      %{^key => value} when is_atom(value) and not is_boolean(value) and not is_nil(value) ->
        if value in allowed do
          Map.put(class, key, value)
        else
          Map.put(class, fingerprint_key(key), fingerprint(prefix <> Atom.to_string(value)))
        end

      _missing_or_open ->
        class
    end
  end

  defp fingerprint_key(:kind), do: :kind_fingerprint
  defp fingerprint_key(:reason), do: :reason_fingerprint

  defp refusal_key_segment(class, atom_key, fingerprint_key) do
    case class do
      %{^atom_key => value} when is_atom(value) -> Atom.to_string(value)
      %{^fingerprint_key => fingerprint} when is_binary(fingerprint) -> fingerprint
      _missing -> "unknown"
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
