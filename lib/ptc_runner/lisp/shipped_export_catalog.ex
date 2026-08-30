defmodule PtcRunner.Lisp.ShippedExportCatalog do
  @moduledoc false

  @spec load() :: %{String.t() => String.t()}
  def load do
    :ptc_runner
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("shipped_export_owners.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
