defmodule PtcRunner.Kernel.RunArtifactName do
  @moduledoc false

  alias PtcRunner.Kernel.TraceDirectoryAdmission

  @directories ~w(traces inspection results envelopes)

  @spec directories() :: [binary()]
  def directories, do: @directories

  @spec ref(binary(), binary()) :: binary() | nil
  def ref("traces", name), do: TraceDirectoryAdmission.run_claim(name)

  def ref(directory, name) when directory in @directories do
    suffix = if directory == "inspection", do: ".ptcins", else: ".json"

    if String.ends_with?(name, suffix) do
      name
      |> String.trim_trailing(suffix)
      |> TraceDirectoryAdmission.canonical_stem()
    end
  end

  def ref(_directory, _name), do: nil

  @spec staged_name(binary()) :: binary()
  def staged_name(path) do
    Path.basename(Path.dirname(path)) <> "-" <> Path.basename(path)
  end

  @spec staged_target(binary(), binary()) :: binary() | nil
  def staged_target(root, name) do
    Enum.find_value(@directories, fn directory ->
      prefix = directory <> "-"

      if String.starts_with?(name, prefix) do
        artifact = String.replace_prefix(name, prefix, "")

        if ref(directory, artifact),
          do: Path.join([root, directory, artifact])
      end
    end)
  end
end
