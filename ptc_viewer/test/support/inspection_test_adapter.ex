defmodule PtcViewer.TestInspectionAdapter do
  @moduledoc false

  def pin_inspection(_path, _trace_source) do
    {:error,
     {:unsupported_inspection_schema_version, %{artifact_version: 4, supported_version: 6}}}
  end

  def conversation(_source, _run_id), do: {:error, :not_called}
end
