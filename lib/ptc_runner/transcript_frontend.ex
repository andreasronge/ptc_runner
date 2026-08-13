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
  alias PtcRunner.Kernel.DeterministicJSON
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

        {:error, _reason} ->
          {:error, :destination_unavailable, "private transcript destination unavailable"}
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

    case validate_separation(handle, traces, inspection) do
      :ok ->
        capture_source(handle, run_id, resources, capture_opts)

      {:error, _reason} ->
        {:error, :source_separation_failed,
         "private transcript sources and destination must be separate"}
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
               {:ok, %{"complete?" => true} = conversation} <-
                 RunAnalysis.query(analysis, :conversation, %{
                   "run_id" => run_id,
                   "limit" => @max_items
                 }),
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
            {:ok, %{"ambiguous?" => true}} ->
              {:error, :ambiguous_evidence, "transcript evidence is ambiguous"}

            {:ok, %{"complete?" => false}} ->
              {:error, :incomplete_evidence, "transcript evidence is incomplete"}

            {:error, :not_found} ->
              {:error, :run_not_found, "analysis run not found"}

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

      {:error, _reason} ->
        {:error, :source_unavailable, "private transcript source unavailable"}
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

  defp validate_separation(handle, traces, inspection) do
    with {:ok, trace} <- AnalysisDirectory.resolve(traces),
         {:ok, private} <- AnalysisDirectory.resolve(inspection),
         {:ok, output} <-
           handle |> PublicationHandle.path() |> Path.dirname() |> AnalysisDirectory.resolve(),
         true <- AnalysisDirectory.pairwise_separate?([trace, private, output]) do
      :ok
    else
      _ -> {:error, :invalid_directory_separation}
    end
  end

  defp finalize_handle(handle, :ok) do
    :ok = PublicationHandle.release(handle)
    :ok
  end

  defp finalize_handle(handle, {:error, _code, _message} = error) do
    PublicationHandle.discard(handle)
    error
  end
end
