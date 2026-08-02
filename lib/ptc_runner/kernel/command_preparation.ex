defmodule PtcRunner.Kernel.CommandPreparation do
  @moduledoc """
  Sealed continuation state for a prepared `validate` or `run` command.

  The command engine consumes application, host, input, and override paths
  before constructing this value. It retains the generated command reference,
  the inert installation catalog needed by later assembly, and only the artifact
  destinations that phase 6 must preflight. If the invocation directory was
  unavailable, it retains the ordered destination keys that could not be
  anchored so phase 6 can apply its fixed trace/inspection/result precedence.
  The path-free `PreparedRun` remains separately sealed inside it.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.CommandRunRef
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.PreparedRun

  @artifact_keys [:trace_dir, :inspect, :output, :private_output]

  @enforce_keys [
    :command,
    :run_ref,
    :prepared_run,
    :catalog,
    :artifact_destinations,
    :artifact_destination_failures
  ]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys [:__struct__, :attestation | @enforce_keys] |> Enum.sort()

  @type t :: %__MODULE__{
          command: :validate | :run,
          run_ref: binary(),
          prepared_run: PreparedRun.t(),
          catalog: InstallationCatalog.t(),
          artifact_destinations: %{optional(atom()) => binary()},
          artifact_destination_failures: [atom()],
          attestation: binary() | nil
        }

  @doc false
  @spec new(
          :validate | :run,
          binary(),
          PreparedRun.t(),
          InstallationCatalog.t(),
          map(),
          [atom()]
        ) :: {:ok, t()} | {:error, :invalid_command_preparation}
  def new(
        command,
        run_ref,
        prepared_run,
        catalog,
        artifact_destinations,
        artifact_destination_failures
      )
      when command in [:validate, :run] and is_map(artifact_destinations) and
             is_list(artifact_destination_failures) do
    preparation = %__MODULE__{
      command: command,
      run_ref: run_ref,
      prepared_run: prepared_run,
      catalog: catalog,
      artifact_destinations: artifact_destinations,
      artifact_destination_failures: artifact_destination_failures
    }

    if fields_valid?(preparation) do
      {:ok,
       %{
         preparation
         | attestation: Attestation.attest(__MODULE__, payload(preparation))
       }}
    else
      {:error, :invalid_command_preparation}
    end
  end

  def new(
        _command,
        _run_ref,
        _prepared_run,
        _catalog,
        _artifact_destinations,
        _artifact_destination_failures
      ),
      do: {:error, :invalid_command_preparation}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{attestation: attestation} = preparation),
    do:
      fields_valid?(preparation) and
        Attestation.valid?(__MODULE__, payload(preparation), attestation)

  def valid?(_preparation), do: false

  @doc "Idempotently releases the embedded prepared run and inert catalog."
  @spec close(t()) :: :ok
  def close(%__MODULE__{prepared_run: prepared_run, catalog: catalog}) do
    PreparedRun.close(prepared_run)
    InstallationCatalog.close(catalog)
  end

  def close(_preparation), do: :ok

  defp fields_valid?(preparation) do
    Enum.sort(Map.keys(preparation)) == @field_keys and
      preparation.command in [:validate, :run] and
      CommandRunRef.valid?(preparation.run_ref) and
      PreparedRun.valid?(preparation.prepared_run) and
      InstallationCatalog.valid?(preparation.catalog) and
      catalog_matches_request?(preparation) and
      artifact_destinations_valid?(
        preparation.command,
        preparation.artifact_destinations,
        preparation.artifact_destination_failures
      ) and
      policy_matches_destinations?(preparation)
  end

  defp catalog_matches_request?(preparation),
    do:
      preparation.catalog.installed_limits ==
        preparation.prepared_run.request.package.installed_limits and
        preparation.catalog.attestation == preparation.prepared_run.catalog_attestation

  defp artifact_destinations_valid?(:validate, destinations, failures),
    do: destinations == %{} and failures == []

  defp artifact_destinations_valid?(:run, destinations, failures) do
    keys = Map.keys(destinations)
    requested_keys = keys ++ failures

    keys -- @artifact_keys == [] and
      failures -- @artifact_keys == [] and
      failures == Enum.filter(@artifact_keys, &(&1 in failures)) and
      Enum.all?(failures, &(&1 not in keys)) and
      Enum.all?(destinations, fn {_key, path} ->
        is_binary(path) and Path.type(path) == :absolute
      end) and
      not (:output in requested_keys and :private_output in requested_keys)
  end

  defp policy_matches_destinations?(preparation) do
    policy = preparation.prepared_run.request.policy

    projection_matches? = policy.result_projection == :json

    inspection_matches? =
      policy.inspection_capture == destination_requested?(preparation, :inspect)

    trace_matches? =
      not destination_requested?(preparation, :trace_dir) or
        (policy.run_id == preparation.run_ref and
           policy.trace_id == preparation.run_ref)

    projection_matches? and inspection_matches? and trace_matches?
  end

  defp destination_requested?(preparation, key),
    do:
      Map.has_key?(preparation.artifact_destinations, key) or
        key in preparation.artifact_destination_failures

  defp payload(preparation) do
    {
      preparation.command,
      preparation.run_ref,
      preparation.prepared_run,
      preparation.catalog,
      preparation.artifact_destinations,
      preparation.artifact_destination_failures
    }
  end
end
