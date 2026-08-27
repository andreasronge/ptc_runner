defmodule PtcRunner.BuildIdentity do
  @moduledoc """
  Source identity embedded in the application at build time.

  Mix records these values in `ptc_runner.app`, so a release reports the
  checkout or explicit hermetic-build revision that produced its BEAM files,
  rather than consulting a Git repository at runtime.
  """

  @type t :: %{
          version: binary(),
          source_revision: binary(),
          source_dirty: boolean()
        }

  @spec current() :: t()
  def current do
    {revision, dirty} = embedded_source_identity()

    %{
      version: application_version(),
      source_revision: revision,
      source_dirty: dirty
    }
  end

  defp application_version do
    :ptc_runner
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp embedded_source_identity do
    case Application.spec(:ptc_runner, :id) |> to_string() |> String.split(":") do
      ["ptc_runner", revision, "true"] -> {revision, true}
      ["ptc_runner", revision, "false"] -> {revision, false}
      _invalid -> raise "ptc_runner application is missing embedded source identity metadata"
    end
  end
end
