Code.require_file("hex_docs_artifact.ex", __DIR__)

docs_config = Mix.Project.config()[:docs]

docs_directory =
  case docs_config do
    config when is_list(config) -> config[:output]
    config when is_function(config, 0) -> config.()[:output]
    _other -> nil
  end || if(File.exists?("doc"), do: "doc", else: "docs")

case System.argv() do
  [output_path] ->
    Mix.Local.append_archives()
    PtcRunner.HexDocsArtifact.build!(docs_directory, output_path)

  ["--", output_path] ->
    Mix.Local.append_archives()
    PtcRunner.HexDocsArtifact.build!(docs_directory, output_path)

  _other ->
    raise "usage: mix run scripts/build_hex_docs.exs -- OUTPUT_PATH"
end
