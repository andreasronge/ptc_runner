Code.require_file("../../scripts/hex_docs_artifact.ex", __DIR__)

defmodule PtcRunner.Scripts.HexPublicationTest do
  use ExUnit.Case, async: true

  @uploader Path.expand("../../scripts/publish_hex_artifact.sh", __DIR__)

  test "docs artifact requires an index and rejects semantic-version top-level paths" do
    temp = temp_directory!()
    on_exit(fn -> File.rm_rf!(temp) end)

    assert_raise RuntimeError, ~r/File not found/, fn ->
      PtcRunner.HexDocsArtifact.build!(temp, Path.join(temp, "docs.tar.gz"))
    end

    File.write!(Path.join(temp, "index.html"), "index")
    version_directory = Path.join(temp, "1.2.3")
    File.mkdir!(version_directory)
    File.write!(Path.join(version_directory, "page.html"), "page")

    assert_raise RuntimeError, ~r/top-level filenames/, fn ->
      PtcRunner.HexDocsArtifact.build!(temp, Path.join(temp, "docs.tar.gz"))
    end
  end

  test "docs artifact contains regular files from the configured directory" do
    temp = temp_directory!()
    output_directory = temp_directory!()
    on_exit(fn -> File.rm_rf!(temp) end)
    on_exit(fn -> File.rm_rf!(output_directory) end)
    File.mkdir_p!(Path.join(temp, "assets"))
    File.write!(Path.join(temp, "index.html"), "index")
    File.write!(Path.join(temp, "assets/app.js"), "javascript")
    output = Path.join(output_directory, "docs.tar.gz")

    Mix.Local.append_archives()
    PtcRunner.HexDocsArtifact.build!(temp, output)

    assert File.stat!(output).size > 0
    assert {:ok, files} = :erl_tar.table(String.to_charlist(output), [:compressed])
    assert ~c"index.html" in files
    assert ~c"assets/app.js" in files
  end

  test "uploader sends exact bytes and fails on non-success responses" do
    temp = temp_directory!()
    on_exit(fn -> File.rm_rf!(temp) end)
    artifact = Path.join(temp, "package.tar")
    File.write!(artifact, "package bytes")

    assert {success, 0} =
             run_uploader(temp, artifact, "201", "packages/example/releases?replace=false")

    assert success == "published package.tar to Hex (201)\n"

    assert {docs, 0} =
             run_uploader(temp, artifact, "201", "packages/example/releases/1.0.0/docs")

    assert docs == "published package.tar to Hex (201)\n"

    assert {failure, 1} =
             run_uploader(temp, artifact, "422", "packages/example/releases?replace=false")

    assert failure =~ "rejected"
  end

  defp run_uploader(temp, artifact, status, api_path) do
    suffix = System.unique_integer([:positive, :monotonic])
    bin = Path.join(temp, "bin-#{status}-#{suffix}")
    File.mkdir!(bin)
    curl = Path.join(bin, "curl")

    File.write!(curl, """
    #!/bin/sh
    output=''
    previous=''
    for argument in "$@"; do
      if [ "$previous" = '--output' ]; then output="$argument"; fi
      previous="$argument"
    done
    printf 'rejected' > "$output"
    printf '%s' "$FAKE_CURL_STATUS"
    """)

    File.chmod!(curl, 0o755)

    System.cmd(
      "bash",
      [@uploader, artifact, api_path],
      env: [
        {"FAKE_CURL_STATUS", status},
        {"HEX_API_KEY", "test-key"},
        {"HEX_API_URL", "https://hex.invalid/api"},
        {"PATH", bin <> ":" <> System.fetch_env!("PATH")}
      ],
      stderr_to_stdout: true
    )
  end

  defp temp_directory! do
    path =
      Path.join(
        System.tmp_dir!(),
        "ptc-hex-publication-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(path)
    path
  end
end
