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

  alias PtcRunner.Lisp.KeyNormalizer

  @label_keys ~w(name model provider tags)
  @tag_values %{
    "environment" => ~w(development test staging production),
    "mode" => ~w(agent deterministic direct wrapper repl),
    "stage" => ~w(started planning executing validating completed failed),
    "suite" => ~w(unit integration e2e conformance privacy)
  }
  @identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,255}\z/
  @fingerprint ~r/\Asha256:[0-9a-f]{64}\z/
  @declarable_failure_kind ~r/\A[a-z][a-z0-9-]{0,63}\z/
  @canonical_annotations ~w(progress agent-action)
  @max_counter 65_535
  @max_vocabulary 16
  @progress_stages ~w(started planning executing validating completed failed)
  @agent_action_kinds ~w(tool-call protocol-error provider-error)
  @failure_kinds ~w(
    invalid-input
    invalid-prompt
    invalid-transcript
    transcript-limit
    turn-limit
    model-program-failed
    non-retryable-evaluation
    llm-provider-error
    protocol-error
    provider-error
    capability-error
    assertion-failed
    unknown-action
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

  @spec annotation?(term(), term(), %{binary() => [binary()]}) :: boolean()
  @doc """
  Returns whether an annotation belongs to a finite canonical vocabulary.

  `"progress"` carries exactly one enumerated `stage`. `"agent-action"` is
  the shipped agent loop's coarse per-turn record: exactly the keys `turn`
  (an integer from 0 through 127, matching the loop's maximum turn count)
  and `kind` (one of `tool-call`, `protocol-error`, or `provider-error`).
  It never carries detailed reasons, generated source, or model content —
  those stay in the agent's own history and, when enabled, in private
  inspection records.

  `declared` adds the annotation types a component declares in its namespace
  metadata, each mapping a type name to the counter names it may carry. Such
  an annotation holds nothing but those counters, each a non-negative integer
  no greater than #{@max_counter}. Both the type and every key therefore come
  from the frozen bundle rather than from the running program, so an
  application outcome reaches a canonical trace without any position where
  caller-chosen text could land.

  A declared counter name stays bounded lowercase kebab-case, matching
  `declarable_annotation?/2` and the Lisp declaration grammar. `data`, by
  the time it reaches here, has already crossed the tool boundary, where
  `PtcRunner.Lisp.KeyNormalizer` rewrites every hyphen in a map key to an
  underscore — so a declared `"already-seen"` counter is matched against a
  `data` key spelled `"already_seen"`. That rewrite is applied only to the
  comparison; the counters passed to `declarable_annotation?/2` are left
  exactly as declared, so a malformed declaration using an underscore still
  fails that check.
  """
  def annotation?(type, data, declared \\ %{})

  def annotation?("progress", %{"stage" => stage} = data, _declared)
      when map_size(data) == 1 and stage in @progress_stages,
      do: true

  def annotation?("agent-action", %{"turn" => turn, "kind" => kind} = data, _declared)
      when map_size(data) == 2 and is_integer(turn) and turn >= 0 and turn <= 127 and
             kind in @agent_action_kinds,
      do: true

  def annotation?(type, data, declared)
      when is_binary(type) and is_map(data) and not is_struct(data) and map_size(data) > 0 and
             is_map(declared) do
    case declared do
      %{^type => counters} ->
        declarable_annotation?(type, counters) and counters_match?(counters, data)

      _undeclared ->
        false
    end
  end

  def annotation?(_type, _data, _declared), do: false

  # Declared counters are kebab-case; `data` keys have already crossed the
  # tool boundary, where `KeyNormalizer.normalize_key/1` rewrites hyphens to
  # underscores. Normalize the declared names the same way, here only, so
  # `declarable_annotation?/2` above keeps seeing the original kebab-case
  # counters — its pattern forbids underscores, so normalizing before that
  # check would make it reject every declared counter it is meant to allow.
  defp counters_match?(counters, data) do
    normalized_counters = Enum.map(counters, &KeyNormalizer.normalize_key/1)

    Enum.all?(data, fn {key, value} ->
      key in normalized_counters and is_integer(value) and value >= 0 and value <= @max_counter
    end)
  end

  @spec declarable_annotation?(term(), term()) :: boolean()
  @doc """
  Returns whether one annotation type and its counter names may be declared.

  Both the type and every counter name are bounded lowercase kebab-case, and a
  declaration may not redefine a canonical type. Counters must be a non-empty
  unique list, so a declared type always carries at least one number.
  """
  def declarable_annotation?(type, counters)
      when is_binary(type) and is_list(counters) and counters != [] and
             length(counters) <= @max_vocabulary do
    type =~ @declarable_failure_kind and type not in @canonical_annotations and
      counters == Enum.uniq(counters) and
      Enum.all?(counters, &(is_binary(&1) and &1 =~ @declarable_failure_kind))
  end

  def declarable_annotation?(_type, _counters), do: false

  @spec failure_taxonomy(term(), [binary()]) :: map()
  @doc """
  Projects an explicit failure value to bounded, payload-free taxonomy.

  Known framework categories remain readable. So does any kind in `declared` —
  a closed vocabulary an application declares in its manifest before a run
  starts, never a name the running program chooses. Everything else is
  represented only by a stable fingerprint, so repeated failures can be grouped
  without putting the caller's value into a public error or trace. Values
  without a scalar `kind` field produce no public taxonomy.

  Naming a declared kind loses no privacy the fingerprint was providing.
  `fingerprint/1` is unsalted, so anyone holding both the trace and the
  manifest can precompute the whole declared set and match it; the fingerprint
  only protects values an observer cannot enumerate. That reasoning holds
  precisely because the vocabulary is closed and fixed at load time, which is
  why the caller must validate entries with `declarable_failure_kind?/1`.
  """
  def failure_taxonomy(value, declared \\ [])

  def failure_taxonomy(value, declared) when is_map(value) and not is_struct(value) do
    value
    |> fetch_failure_kind()
    |> normalize_failure_kind(declared)
  end

  def failure_taxonomy(_value, _declared), do: %{}

  @spec declarable_failure_kind?(term()) :: boolean()
  @doc """
  Returns whether one name may be declared as an application failure kind.

  Bounded lowercase kebab-case, so a declared vocabulary cannot carry prose,
  punctuation, or an entity name into a canonical trace. Framework kinds are
  rejected: declaring one is either redundant or an attempt to make an
  application failure read as a framework failure.
  """
  def declarable_failure_kind?(kind) when is_binary(kind),
    do: kind =~ @declarable_failure_kind and kind not in @failure_kinds

  def declarable_failure_kind?(_kind), do: false

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

  defp metadata_name(%PtcRunner.Lisp.Keyword{name: name}), do: name
  defp metadata_name(value) when is_atom(value), do: Atom.to_string(value)
  defp metadata_name(value) when is_binary(value), do: value
  defp metadata_name(_value), do: nil

  defp normalize_failure_kind(%PtcRunner.Lisp.Keyword{name: kind}, declared),
    do: normalize_failure_kind(kind, declared)

  defp normalize_failure_kind(kind, declared) when is_atom(kind),
    do: kind |> Atom.to_string() |> normalize_failure_kind(declared)

  defp normalize_failure_kind(kind, declared)
       when is_binary(kind) and byte_size(kind) in 1..256 do
    if String.valid?(kind) do
      normalized = String.replace(kind, "_", "-")

      if normalized in @failure_kinds or named?(normalized, declared),
        do: %{failure_kind: normalized},
        else: %{failure_kind_fingerprint: fingerprint("failure-kind:" <> kind)}
    else
      %{}
    end
  end

  defp normalize_failure_kind(_kind, _declared), do: %{}

  # A malformed declaration never widens the taxonomy: an entry that would not
  # survive `declarable_failure_kind?/1` cannot name a kind here either, so a
  # loader bug degrades to fingerprinting rather than to arbitrary text.
  defp named?(kind, declared) when is_list(declared),
    do: kind in declared and declarable_failure_kind?(kind)

  defp named?(_kind, _declared), do: false

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
