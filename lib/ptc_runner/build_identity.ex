defmodule PtcRunner.BuildIdentity do
  @moduledoc """
  Source provenance embedded when PtcRunner is compiled.

  The full revision and dirty flag are stored in generated OTP application
  metadata. This makes identity changes visible to Mix's app compiler instead
  of baking a potentially stale Git query into an otherwise reusable BEAM.
  Hermetic builds provide `PTC_SOURCE_REVISION` and `PTC_SOURCE_DIRTY`.
  """

  @type t :: %{
          version: binary(),
          source_revision: binary(),
          source_dirty: boolean()
        }

  @spec current() :: t()
  def current do
    identity = Application.fetch_env!(:ptc_runner, :build_identity)

    %{
      version: :ptc_runner |> Application.spec(:vsn) |> List.to_string(),
      source_revision: Keyword.fetch!(identity, :source_revision),
      source_dirty: Keyword.fetch!(identity, :source_dirty)
    }
  end

  @spec human(t()) :: binary()
  def human(%{version: version, source_revision: revision, source_dirty: dirty?}) do
    state = if dirty?, do: "dirty", else: "clean"
    "#{version} (#{String.slice(revision, 0, 8)}, #{state})"
  end
end
