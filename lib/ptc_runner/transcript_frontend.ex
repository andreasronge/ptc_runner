defmodule PtcRunner.TranscriptFrontend do
  @moduledoc """
  One-shot private conversation retrieval for an immutable selected run capture.

  The command reserves an owner-only destination before touching either
  evidence directory, then captures exactly one canonical trace candidate and
  one canonical inspection artifact for `RUN_ID`. Unrelated files in those
  directories are not listed, opened, sized, decoded, or counted. The shared
  `RunAnalysis` read model answers one question, and the command publishes
  deterministic JSON atomically. `--private-unattended` is an explicit accident
  guard, not access control; same-UID callers able to invoke this command can
  already read the supplied artifacts.
  """

  alias PtcRunner.Kernel.AnalysisDirectory
  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.ConversationProjection
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.DirectorySeparation
  alias PtcRunner.Kernel.PrivateRunAnalysisProfile
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.RunAnalysis

  @max_items 1_000

  @spec run(CommandArguments.t(), CommandRuntime.t()) ::
          :ok | {:error, atom(), binary()}
  def run(arguments, runtime), do: run(arguments, runtime, [])

  @doc false
  @spec run(CommandArguments.t(), CommandRuntime.t(), keyword()) ::
          :ok | {:error, atom(), binary()}
  def run(
        %CommandArguments{
          command: :transcript,
          application: run_id,
          options: %{
            traces: traces,
            inspection: inspection,
            private_unattended: true,
            private_output: output
          }
        },
        %CommandRuntime{},
        capture_opts
      ) do
    if valid_capture_opts?(capture_opts) do
      case PublicationHandle.reserve(output, :result, 0o600) do
        {:ok, handle} ->
          result = capture_and_publish(handle, run_id, traces, inspection, capture_opts)
          finalize_handle(handle, result)

        {:error, reason} ->
          destination_error(reason)
      end
    else
      {:error, :invalid_arguments, "invalid transcript command"}
    end
  rescue
    _exception -> {:error, :internal_error, "transcript command failed"}
  catch
    _kind, _reason -> {:error, :internal_error, "transcript command failed"}
  end

  def run(_arguments, _runtime, _capture_opts),
    do: {:error, :invalid_arguments, "invalid transcript command"}

  defp capture_and_publish(handle, run_id, traces, inspection, capture_opts) do
    resources = %{"traces" => traces, "inspection" => inspection}

    case validate_sources_and_separation(handle, traces, inspection) do
      :ok ->
        capture_source(handle, run_id, resources, capture_opts)

      {:error, _code, _message} = error ->
        error
    end
  end

  defp capture_source(handle, run_id, resources, capture_opts) do
    case PrivateRunAnalysisProfile.capture(
           resources,
           Keyword.put(capture_opts, :selected_run_ref, run_id)
         ) do
      {:ok, captured} ->
        try do
          publish_selected_transcript(handle, run_id, captured)
        after
          AnalysisResources.stop(captured)
        end

      {:error, reason} ->
        selected_capture_error(reason)
    end
  end

  defp publish_selected_transcript(handle, run_id, captured) do
    with {:ok, analysis} <-
           RunAnalysis.new(
             AnalysisResources.handle(captured, :traces),
             AnalysisResources.handle(captured, :inspection)
           ),
         {:ok, turns} <- RunAnalysis.collect(analysis, run_id, "turns", @max_items),
         conversation = ConversationProjection.present_page(turns),
         :ok <- admissible_evidence(conversation),
         {:ok, encoded} <-
           DeterministicJSON.encode(%{
             "schema_version" => 1,
             "run_id" => run_id,
             "conversation" => conversation
           }),
         :ok <- PublicationHandle.write(handle, encoded <> "\n"),
         :ok <- PublicationHandle.sync(handle),
         :ok <- PublicationHandle.publish(handle) do
      :ok
    else
      {:error, _code, _message} = classified -> classified
      {:error, reason} -> selected_publish_error(reason)
    end
  end

  defp selected_capture_error(:source_changed),
    do: {:error, :source_changed, "analysis source changed during capture"}

  defp selected_capture_error(:invalid_run_reference),
    do: {:error, :invalid_run_reference, "RUN_ID must be a canonical PTC command run reference"}

  defp selected_capture_error(:selected_trace_missing),
    do:
      {:error, :selected_trace_missing,
       "RUN_ID does not name a canonical trace artifact under --traces"}

  defp selected_capture_error(:ambiguous_selected_trace),
    do:
      {:error, :ambiguous_selected_trace,
       "RUN_ID names both canonical trace candidates under --traces"}

  defp selected_capture_error(:selected_inspection_missing),
    do:
      {:error, :selected_inspection_missing,
       "RUN_ID does not name a canonical inspection artifact under --inspection"}

  defp selected_capture_error(:selected_trace_not_regular),
    do:
      {:error, :selected_trace_not_regular,
       "the selected --traces artifact must be a regular file, not a symbolic link"}

  defp selected_capture_error(:selected_inspection_not_regular),
    do:
      {:error, :selected_inspection_not_regular,
       "the selected --inspection artifact must be a regular file, not a symbolic link"}

  defp selected_capture_error(:selected_run_mismatch),
    do:
      {:error, :selected_run_mismatch,
       "the selected --traces and --inspection artifacts do not declare RUN_ID"}

  defp selected_capture_error(reason)
       when reason in [:inspection_correlation_missing, :incomplete_inspection_correlation],
       do:
         {:error, :inspection_correlation_missing,
          "the selected --traces and --inspection artifacts do not correlate"}

  defp selected_capture_error(:malformed_source),
    do: {:error, :malformed_source, "the selected transcript source is malformed"}

  defp selected_capture_error(:unsupported_version),
    do:
      {:error, :unsupported_schema,
       "the selected transcript source uses an unsupported schema version"}

  defp selected_capture_error(:source_limit_exceeded),
    do: {:error, :source_limit_exceeded, "the selected transcript source exceeded its limit"}

  defp selected_capture_error(:empty_traces_resource),
    do:
      {:error, :source_unavailable, "--traces must contain at least one canonical trace artifact"}

  defp selected_capture_error(:empty_inspection_resource),
    do:
      {:error, :source_unavailable,
       "--inspection must contain at least one correlated inspection artifact"}

  defp selected_capture_error({:source_retained_limit_exceeded, _details}),
    do: {:error, :source_limit_exceeded, "the selected transcript source exceeded its limit"}

  defp selected_capture_error(:source_retained_limit_exceeded),
    do: {:error, :source_limit_exceeded, "the selected transcript source exceeded its limit"}

  defp selected_capture_error(_reason),
    do:
      {:error, :source_unavailable,
       "--traces or --inspection could not be captured as private transcript sources"}

  defp selected_publish_error(:not_found),
    do:
      {:error, :run_not_found,
       "RUN_ID was not found in the correlated --traces and --inspection sources"}

  defp selected_publish_error(:source_changed),
    do: {:error, :source_changed, "analysis source changed during capture"}

  defp selected_publish_error(:result_limit_exceeded),
    do: {:error, :result_limit_exceeded, "transcript result limit exceeded"}

  defp selected_publish_error(:evidence_unavailable),
    do: {:error, :evidence_unavailable, "private transcript evidence unavailable"}

  defp selected_publish_error(_reason),
    do: {:error, :evidence_unavailable, "private transcript unavailable"}

  # The projection measures three independent conditions and `complete?`
  # collapses them into one boolean. Refusing on the boolean is right; reporting
  # it as "incomplete" is not, because an ambiguous reconstruction is missing
  # nothing and sends the reader hunting for artifacts they already have. The
  # counts are already computed, so each cause names itself and its magnitude.
  defp admissible_evidence(conversation) do
    ambiguity = count(conversation, "ambiguity_count")
    missing = count(conversation, "missing_exchange_count")

    cond do
      not conversation["canonical_complete?"] ->
        {:error, :incomplete_evidence,
         "transcript evidence is incomplete: the canonical trace records no terminal run " <>
           "event or reports dropped events, so the conversation cannot be certified " <>
           "(#{missing} missing model #{plural(missing, "exchange")}, " <>
           "#{ambiguity} ambiguous #{plural(ambiguity, "association")}). " <> ungated_repl_hint()}

      missing > 0 ->
        {:error, :incomplete_evidence,
         "transcript evidence is incomplete: #{missing} model " <>
           "#{plural(missing, "exchange")} the canonical trace expects " <>
           "#{plural(missing, "was", "were")} not captured under --inspection " <>
           "(#{ambiguity} ambiguous #{plural(ambiguity, "association")}). " <>
           ungated_repl_hint()}

      ambiguity > 0 ->
        {:error, :ambiguous_evidence,
         "transcript evidence is ambiguous: #{ambiguity} turn or generated-source " <>
           "#{plural(ambiguity, "association")} #{plural(ambiguity, "resolves", "resolve")} " <>
           "to more than one predecessor. Nothing is missing: the canonical trace is " <>
           "complete and every expected model exchange was captured. " <> ungated_repl_hint()}

      true ->
        :ok
    end
  end

  # `ptc transcript` publishes only a reconstruction it can certify. The
  # private analysis profile applies no such gate and is present in every
  # distribution, so it is the next action for every refusal above.
  defp ungated_repl_hint,
    do:
      "The same reconstruction is ungated in ptc repl --profile private-run-analysis-v2; " <>
        "see ptc docs repl."

  defp count(conversation, key) do
    case Map.get(conversation, key) do
      value when is_integer(value) and value >= 0 -> value
      _absent -> 0
    end
  end

  defp plural(count, singular, plural \\ nil)
  defp plural(1, singular, _plural), do: singular
  defp plural(_count, singular, nil), do: singular <> "s"
  defp plural(_count, _singular, plural), do: plural

  defp valid_capture_opts?(opts) when is_list(opts) do
    Keyword.keys(opts) --
      [
        :capture_hook,
        :listing_hook,
        :inspection_capture_hook,
        :inspection_listing_hook,
        :inspection_artifact_verification_hook
      ] == []
  end

  defp valid_capture_opts?(_opts), do: false

  defp validate_sources_and_separation(handle, traces, inspection) do
    with {:ok, trace} <- resolve_source(traces, :traces),
         {:ok, private} <- resolve_source(inspection, :inspection),
         {:ok, output} <-
           handle
           |> PublicationHandle.path()
           |> Path.dirname()
           |> resolve_output_directory() do
      validate_separation(trace, private, output)
    end
  end

  defp resolve_source(directory, :traces) do
    case AnalysisDirectory.resolve(directory) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, _reason} ->
        {:error, :source_unavailable, "--traces must name an existing directory"}
    end
  end

  defp resolve_source(directory, :inspection) do
    case AnalysisDirectory.resolve(directory) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, _reason} ->
        {:error, :source_unavailable, "--inspection must name an existing directory"}
    end
  end

  # `reserve/3` has already established that the parent exists, is a directory,
  # and is owner-safe, so the only rule left for this resolution to enforce is
  # the physical one: identity is read through `lstat`, which a symbolic link
  # fails. Naming it is the difference between a rule and a restatement.
  defp resolve_output_directory(directory) do
    case AnalysisDirectory.resolve(directory) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, _reason} ->
        {:error, :destination_parent_unavailable,
         "the parent directory for --private-output must be an existing directory reached " <>
           "without a symbolic link"}
    end
  end

  defp validate_separation(trace, private, output) do
    labelled = [
      {%{id: "traces", label: "--traces"}, trace},
      {%{id: "inspection", label: "--inspection"}, private},
      {%{id: "private_output", label: "--private-output"}, output}
    ]

    case DirectorySeparation.verify(labelled) do
      :ok -> :ok
      {:error, %{message: message}} -> {:error, :source_separation_failed, message}
    end
  end

  # Every reason below is one the reservation already distinguished. Collapsing
  # them into a single "unavailable" made three independent readers infer three
  # different rules from the same sentence, so each keeps its own code and says
  # which rule it broke.
  defp destination_error(:destination_exists),
    do: {:error, :destination_exists, "--private-output already exists; choose a new file"}

  defp destination_error(:destination_directory_missing),
    do:
      {:error, :destination_directory_missing,
       "the parent directory for --private-output does not exist; create it first"}

  defp destination_error(:private_directory_parent_unsafe),
    do:
      {:error, :destination_parent_unsafe,
       "the parent directory for --private-output is group- or world-writable; an owner-only " <>
         "artifact refuses a parent other users can write to. On macOS /tmp is world-writable " <>
         "and symlinked; use a directory under your home instead"}

  defp destination_error(:private_directory_parent_unavailable),
    do:
      {:error, :destination_parent_unavailable,
       "--private-output must name a file whose parent is an existing directory you own; " <>
         "its parent is not an existing directory"}

  defp destination_error(:invalid_destination),
    do: {:error, :invalid_destination, "--private-output must name a valid new file"}

  defp destination_error(_reason),
    do: {:error, :destination_unavailable, "--private-output destination is unavailable"}

  defp finalize_handle(handle, :ok) do
    :ok = PublicationHandle.release(handle)
    :ok
  end

  defp finalize_handle(handle, {:error, _code, _message} = error) do
    PublicationHandle.discard(handle)
    error
  end
end
