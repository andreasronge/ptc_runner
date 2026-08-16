defmodule PtcRunner.TranscriptFrontend do
  @moduledoc """
  One-shot private conversation retrieval for an immutable run capture.

  The command reserves an owner-only destination before touching either
  evidence directory, captures the sealed private analysis recipe, asks the
  shared `RunAnalysis` read model one question, and publishes deterministic
  JSON atomically. `--private-unattended` is an explicit accident guard, not
  access control; same-UID callers able to invoke this command can already read
  the supplied artifacts.
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
    case PrivateRunAnalysisProfile.capture(resources, capture_opts) do
      {:ok, captured} ->
        try do
          with {:ok, analysis} <-
                 RunAnalysis.new(
                   AnalysisResources.handle(captured, :traces),
                   AnalysisResources.handle(captured, :inspection)
                 ),
               {:ok, turns} <- RunAnalysis.collect(analysis, run_id, "turns", @max_items),
               conversation = ConversationProjection.present_page(turns),
               true <- conversation["complete?"] and not conversation["ambiguous?"],
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
            false ->
              {:error, :incomplete_evidence, "transcript evidence is incomplete or ambiguous"}

            {:error, :not_found} ->
              {:error, :run_not_found,
               "RUN_ID was not found in the correlated --traces and --inspection sources"}

            {:error, :source_changed} ->
              {:error, :source_changed, "analysis source changed during capture"}

            {:error, :result_limit_exceeded} ->
              {:error, :result_limit_exceeded, "transcript result limit exceeded"}

            {:error, :evidence_unavailable} ->
              {:error, :evidence_unavailable, "private transcript evidence unavailable"}

            {:error, _reason} ->
              {:error, :evidence_unavailable, "private transcript unavailable"}
          end
        after
          AnalysisResources.stop(captured)
        end

      {:error,
       {:unsupported_inspection_schema_version,
        %{artifact_version: artifact_version, supported_version: supported_version}}} ->
        {:error, :unsupported_schema,
         "inspection artifact schema version #{artifact_version} is unsupported; " <>
           "this build supports version #{supported_version}"}

      {:error, :source_changed} ->
        {:error, :source_changed, "analysis source changed during capture"}

      {:error, :empty_traces_resource} ->
        {:error, :source_unavailable,
         "--traces must contain at least one canonical trace artifact"}

      {:error, :empty_inspection_resource} ->
        {:error, :source_unavailable,
         "--inspection must contain at least one correlated inspection artifact"}

      {:error, _reason} ->
        {:error, :source_unavailable,
         "--traces or --inspection could not be captured as private transcript sources"}
    end
  end

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

  defp resolve_output_directory(directory) do
    case AnalysisDirectory.resolve(directory) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, _reason} ->
        {:error, :destination_unavailable,
         "the parent directory for --private-output is unavailable"}
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

  defp destination_error(:destination_exists),
    do: {:error, :destination_exists, "--private-output already exists; choose a new file"}

  defp destination_error(:invalid_destination),
    do: {:error, :destination_unavailable, "--private-output must name a valid new file"}

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
