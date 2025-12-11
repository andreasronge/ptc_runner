defmodule Mix.Tasks.Ptc.InstallBabashka do
  @moduledoc """
  Installs Babashka for Clojure validation.

  Downloads the appropriate binary for your OS/architecture
  and places it in `_build/tools/bb`.

  ## Usage

      mix ptc.install_babashka
      mix ptc.install_babashka --force     # Reinstall even if present
      mix ptc.install_babashka --version 1.4.192  # Specific version

  ## Supported Platforms

  - macOS (Apple Silicon and Intel)
  - Linux (x86_64)

  ## What This Does

  1. Detects your OS and architecture
  2. Downloads the appropriate Babashka binary from GitHub releases
  3. Extracts and places it at `_build/tools/bb`
  4. Makes the binary executable
  5. Verifies the installation
  """

  use Mix.Task

  @shortdoc "Install Babashka for Clojure validation"

  @default_version "1.4.192"
  @download_base "https://github.com/babashka/babashka/releases/download"
  @install_dir "_build/tools"
  @bb_path "_build/tools/bb"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [force: :boolean, version: :string],
        aliases: [f: :force, v: :version]
      )

    force = Keyword.get(opts, :force, false)
    version = Keyword.get(opts, :version, @default_version)

    # Check if already installed
    if File.exists?(@bb_path) and not force do
      Mix.shell().info("Babashka already installed at #{@bb_path}")
      Mix.shell().info("Use --force to reinstall")
      verify_installation()
      :ok
    else
      install_babashka(version)
    end
  end

  defp install_babashka(version) do
    Mix.shell().info("Installing Babashka v#{version}...")

    # Detect OS and architecture
    {os, arch} = detect_platform()
    Mix.shell().info("Detected platform: #{os}/#{arch}")

    # Build download URL
    filename = build_filename(os, arch, version)
    url = "#{@download_base}/v#{version}/#{filename}"
    Mix.shell().info("Downloading from: #{url}")

    # Create install directory
    File.mkdir_p!(@install_dir)

    # Download
    archive_path = Path.join(@install_dir, filename)

    case download_file(url, archive_path) do
      :ok ->
        Mix.shell().info("Downloaded successfully")

        # Extract
        extract_archive(archive_path, @install_dir)
        File.rm(archive_path)

        # Make executable
        File.chmod!(@bb_path, 0o755)

        Mix.shell().info("Installed Babashka to #{@bb_path}")
        verify_installation()

      {:error, reason} ->
        Mix.raise("Failed to download Babashka: #{reason}")
    end
  end

  defp detect_platform do
    os =
      case :os.type() do
        {:unix, :darwin} -> :macos
        {:unix, :linux} -> :linux
        {:win32, _} -> :windows
        other -> Mix.raise("Unsupported OS: #{inspect(other)}")
      end

    arch =
      case :erlang.system_info(:system_architecture) |> to_string() do
        "aarch64" <> _ -> :aarch64
        "arm64" <> _ -> :aarch64
        "x86_64" <> _ -> :amd64
        "amd64" <> _ -> :amd64
        other -> Mix.raise("Unsupported architecture: #{other}")
      end

    {os, arch}
  end

  defp build_filename(os, arch, version) do
    case {os, arch} do
      {:macos, :aarch64} ->
        "babashka-#{version}-macos-aarch64.tar.gz"

      {:macos, :amd64} ->
        "babashka-#{version}-macos-amd64.tar.gz"

      {:linux, :amd64} ->
        "babashka-#{version}-linux-amd64-static.tar.gz"

      {:linux, :aarch64} ->
        "babashka-#{version}-linux-aarch64-static.tar.gz"

      {os, arch} ->
        Mix.raise("Unsupported platform: #{os}/#{arch}")
    end
  end

  defp download_file(url, dest_path) do
    # Use curl for reliable downloading with redirect support
    case System.cmd("curl", ["-L", "-o", dest_path, "-f", "--silent", "--show-error", url],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, code} ->
        {:error, "curl failed (exit #{code}): #{output}"}
    end
  end

  defp extract_archive(archive_path, dest_dir) do
    Mix.shell().info("Extracting archive...")

    case System.cmd("tar", ["-xzf", archive_path, "-C", dest_dir]) do
      {_, 0} ->
        :ok

      {output, code} ->
        Mix.raise("Failed to extract archive (exit code #{code}): #{output}")
    end
  end

  defp verify_installation do
    # Use absolute path for verification
    bb_abs_path = Path.join(File.cwd!(), @bb_path)

    case System.cmd(bb_abs_path, ["--version"]) do
      {version, 0} ->
        Mix.shell().info("Verified: #{String.trim(version)}")
        :ok

      {output, code} ->
        Mix.shell().error("Verification failed (exit code #{code}): #{output}")
        :error
    end
  end
end
