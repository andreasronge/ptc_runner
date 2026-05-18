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
  @allowed_download_hosts [
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com"
  ]
  @version_pattern ~r/^\d+\.\d+\.\d+$/
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

    validate_version!(version)

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
    checksum_url = "#{url}.sha256"
    Mix.shell().info("Downloading from: #{url}")

    # Create install directory
    File.mkdir_p!(@install_dir)

    # Download
    archive_path = Path.join(@install_dir, filename)
    checksum_path = "#{archive_path}.sha256"

    with :ok <- download_file(checksum_url, checksum_path),
         :ok <- download_file(url, archive_path),
         :ok <- verify_checksum(archive_path, checksum_path) do
      Mix.shell().info("Downloaded successfully")
      File.rm(checksum_path)

      # Extract
      extract_archive(archive_path, @install_dir)
      File.rm(archive_path)

      # Make executable
      File.chmod!(@bb_path, 0o755)

      Mix.shell().info("Installed Babashka to #{@bb_path}")
      verify_installation()
    else
      {:error, reason} ->
        Mix.raise("Failed to download Babashka: #{reason}")
    end
  end

  defp validate_version!(version) do
    if Regex.match?(@version_pattern, version) do
      :ok
    else
      Mix.raise("Invalid Babashka version #{inspect(version)}. Expected MAJOR.MINOR.PATCH.")
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
    with :ok <- validate_download_url(url),
         {:ok, resolved_url} <- resolve_download_url(url),
         :ok <- validate_download_url(resolved_url) do
      curl_download(resolved_url, dest_path)
    end
  end

  defp validate_download_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: port}
      when host in @allowed_download_hosts and port in [nil, 443] ->
        :ok

      %URI{} ->
        {:error, "refusing to download from untrusted URL: #{url}"}
    end
  end

  defp resolve_download_url(url) do
    # Resolve GitHub release redirects with HTTPS-only redirect handling before downloading bytes.
    args = [
      "--head",
      "--location",
      "--max-redirs",
      "5",
      "--proto",
      "=https",
      "--proto-redir",
      "=https",
      "--fail",
      "--silent",
      "--show-error",
      "--output",
      "/dev/null",
      "--write-out",
      "%{url_effective}",
      url
    ]

    case System.cmd("curl", args, stderr_to_stdout: true) do
      {resolved_url, 0} ->
        {:ok, String.trim(resolved_url)}

      {output, code} ->
        {:error, "curl failed while resolving redirects (exit #{code}): #{output}"}
    end
  end

  defp curl_download(url, dest_path) do
    # Download the already-resolved HTTPS URL without following additional redirects.
    case System.cmd("curl", ["-o", dest_path, "-f", "--silent", "--show-error", url],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, code} ->
        {:error, "curl failed (exit #{code}): #{output}"}
    end
  end

  defp verify_checksum(archive_path, checksum_path) do
    with {:ok, expected} <- read_expected_checksum(checksum_path),
         {:ok, actual} <- sha256_file(archive_path) do
      if expected == actual do
        :ok
      else
        {:error, "SHA-256 mismatch for #{archive_path}"}
      end
    end
  end

  defp read_expected_checksum(checksum_path) do
    with {:ok, content} <- File.read(checksum_path),
         [checksum] <- Regex.run(~r/\b[0-9a-fA-F]{64}\b/, content) do
      {:ok, String.downcase(checksum)}
    else
      {:error, reason} -> {:error, "failed to read checksum file: #{inspect(reason)}"}
      _ -> {:error, "checksum file did not contain a SHA-256 digest"}
    end
  end

  defp sha256_file(path) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, "failed to read downloaded archive: #{inspect(reason)}"}
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
