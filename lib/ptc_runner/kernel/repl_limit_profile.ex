defmodule PtcRunner.Kernel.ReplLimitProfile do
  @moduledoc false

  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Manifest

  @session_lifetime_fields [:run_duration_ms, :subordinate_evaluations]
  @direct_event_fields [:normal_event_count, :normal_event_bytes]
  @manifest_interactive_fields @session_lifetime_fields ++ @direct_event_fields

  @doc false
  @spec direct_interactive() :: Limits.t()
  def direct_interactive do
    maxima =
      Map.new(@session_lifetime_fields, fn field ->
        {:ok, row} = LimitCatalog.fetch(field)
        {field, row.maximum}
      end)

    installed_events =
      Limits.installed_defaults()
      |> Map.from_struct()
      |> Map.take(@direct_event_fields)

    {:ok, limits} = Limits.new(Map.merge(maxima, installed_events))
    limits
  end

  @doc false
  @spec apply_manifest(Manifest.t(), boolean()) :: {:ok, Manifest.t()} | {:error, :invalid_limits}
  def apply_manifest(%Manifest{} = manifest, false), do: {:ok, manifest}

  def apply_manifest(%Manifest{} = manifest, true) do
    declared = Map.get(manifest.document, "limits", %{})
    ceilings = Map.from_struct(manifest.installed_limits)

    values =
      Enum.reduce(@manifest_interactive_fields, Map.from_struct(manifest.limits), fn field, acc ->
        if Map.has_key?(declared, Atom.to_string(field)),
          do: acc,
          else: Map.put(acc, field, Map.fetch!(ceilings, field))
      end)

    with {:ok, limits} <- Limits.new(values),
         do: {:ok, %{manifest | limits: limits}}
  end
end
