defmodule PtcViewer.LiveProject do
  @moduledoc """
  Host-injected project details for the Live tab (#1444).

  The Viewer has no dependency on any kernel, so it cannot read a manifest
  itself. An operator supplies a `project_adapter` — a zero-arity function, or
  a module exporting `describe/0` — and the Viewer serves whatever map comes
  back as opaque data: it neither validates the shape nor assigns meaning to
  the fields.

  The panel is a convenience, never a reason to lose the dashboard: an adapter
  that raises, exits, or returns something other than a map degrades to
  `%{"enabled" => false}` instead of failing the request.
  """

  @disabled %{"enabled" => false}

  @doc "Validates an operator-supplied adapter at Viewer startup."
  @spec validate(term()) :: :ok | {:error, :invalid_project_config}
  def validate(nil), do: :ok
  def validate(adapter) when is_function(adapter, 0), do: :ok

  def validate(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :describe, 0),
      do: :ok,
      else: {:error, :invalid_project_config}
  end

  def validate(_adapter), do: {:error, :invalid_project_config}

  @doc """
  Invokes the adapter and returns its payload with `"enabled" => true` added.

  Both a bare map and an `{:ok, map}` are accepted, so a host can pass a
  builder that reports failures the usual way without unwrapping it first.
  """
  @spec describe(term()) :: map()
  def describe(nil), do: @disabled

  def describe(adapter) do
    adapter |> invoke() |> normalize()
  rescue
    _exception -> @disabled
  catch
    _kind, _reason -> @disabled
  end

  defp invoke(adapter) when is_function(adapter, 0), do: adapter.()
  defp invoke(adapter) when is_atom(adapter), do: adapter.describe()
  defp invoke(_adapter), do: nil

  defp normalize({:ok, project}) when is_map(project), do: normalize(project)
  defp normalize(project) when is_map(project), do: Map.put(project, "enabled", true)
  defp normalize(_invalid), do: @disabled
end
