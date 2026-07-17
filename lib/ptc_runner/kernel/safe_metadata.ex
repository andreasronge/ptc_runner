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
  @doc "Returns whether an annotation belongs to the finite canonical vocabulary."
  def annotation?("progress", %{"stage" => stage}) when stage in @progress_stages, do: true

  def annotation?(_type, _data), do: false

  @spec fingerprint(binary()) :: binary()
  @doc "Returns the canonical non-reversible fingerprint for one bounded identifier."
  def fingerprint(value) when is_binary(value) do
    if fingerprint?(value) do
      value
    else
      "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
    end
  end

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
