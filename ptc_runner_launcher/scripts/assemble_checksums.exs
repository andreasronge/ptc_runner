if length(System.argv()) != 2 do
  IO.puts(:stderr, "usage: assemble_checksums.exs ARTIFACT_DIRECTORY OUTPUT")
  System.halt(64)
end

[artifact_directory, output_path] = Enum.map(System.argv(), &Path.expand/1)
launcher_root = Path.expand("..", __DIR__)
{release_config, _bindings} = Code.eval_file(Path.join(launcher_root, "release_config.exs"))

targets =
  release_config.precompiled_targets
  |> Map.values()
  |> Enum.flat_map(&Map.keys/1)
  |> Enum.sort()

expected_archives =
  Enum.map(
    targets,
    &"ptc_runner_launcher-port-#{&1}-#{release_config.version}.tar.gz"
  )

actual_archives =
  artifact_directory
  |> Path.join("*.tar.gz")
  |> Path.wildcard()
  |> Enum.map(&Path.basename/1)
  |> Enum.sort()

unless actual_archives == expected_archives do
  raise """
  release artifact set does not match configured targets
  expected: #{inspect(expected_archives)}
  actual:   #{inspect(actual_archives)}
  """
end

checksums =
  Enum.map(expected_archives, fn basename ->
    archive_path = Path.join(artifact_directory, basename)
    checksum_path = archive_path <> ".sha256"

    [declared_checksum, declared_basename] =
      checksum_path
      |> File.read!()
      |> String.split(~r/\s+/, trim: true)

    unless declared_basename == basename do
      raise "#{checksum_path} names #{inspect(declared_basename)}, expected #{inspect(basename)}"
    end

    actual_checksum =
      archive_path
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    unless declared_checksum == actual_checksum do
      raise "#{basename} does not match its adjacent SHA-256 file"
    end

    {:ok, entries} = :erl_tar.table(String.to_charlist(archive_path), [:compressed])

    unless entries == [~c"ptc_runner_launcher"] do
      raise "#{basename} has unexpected archive entries: #{inspect(entries)}"
    end

    {basename, actual_checksum}
  end)

lines =
  Enum.map(checksums, fn {basename, checksum} ->
    ~s(  "#{basename}" => "sha256:#{checksum}",\n)
  end)

File.write!(output_path, ["%{\n", lines, "}\n"])
