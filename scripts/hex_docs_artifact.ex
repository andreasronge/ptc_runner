defmodule PtcRunner.HexDocsArtifact do
  @moduledoc false

  def build!(docs_directory, output_path) do
    index = Path.join(docs_directory, "index.html")

    unless File.regular?(index) do
      raise "File not found: #{index}"
    end

    files =
      docs_directory
      |> Path.join("**")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn path ->
        relative = path |> Path.relative_to(docs_directory) |> String.to_charlist()
        reject_semver_top_level!(relative)
        {relative, File.read!(path)}
      end)

    {:ok, tarball} = apply(:mix_hex_tarball, :create_docs, [files])
    File.write!(output_path, tarball)
  end

  defp reject_semver_top_level!(filename) do
    top_level = filename |> Path.split() |> List.first() |> to_string()

    if match?({:ok, _version}, Version.parse(top_level)) do
      raise "Invalid filename: top-level filenames cannot match a semantic version pattern"
    end
  end
end
