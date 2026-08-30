defmodule PtcRunner.Lisp.ShippedExportCatalog do
  @moduledoc false

  @external_resource Path.expand("../../../priv/shipped_export_owners.json", __DIR__)
  @owners @external_resource |> File.read!() |> Jason.decode!()

  @spec load() :: %{String.t() => String.t()}
  def load, do: @owners
end
