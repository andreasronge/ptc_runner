defmodule Mix.Tasks.Ptc.InstallClojure do
  @shortdoc "Install the pinned JVM Clojure oracle jars"
  @moduledoc """
  Installs the checksum-pinned Clojure jars used by Java interop fixtures.

      mix ptc.install_clojure
      mix ptc.install_clojure --force

  The runtime is installed beneath `_build/tools`; it does not use a system
  Clojure CLI, project `deps.edn`, or user Clojure configuration.
  """

  use Mix.Task

  alias PtcRunner.Lisp.Java.Oracle.ClojureRuntime

  @impl Mix.Task
  def run(args) do
    {opts, _remaining, _invalid} = OptionParser.parse(args, strict: [force: :boolean])
    force? = Keyword.get(opts, :force, false)

    if ClojureRuntime.installed?() and not force? do
      Mix.shell().info("Pinned JVM Clojure is already installed")
    else
      install!()
    end
  end

  defp install! do
    install_dir = ClojureRuntime.install_dir()
    File.mkdir_p!(install_dir)

    Enum.each(ClojureRuntime.artifacts(), fn artifact ->
      destination = Path.join(install_dir, artifact.filename)
      temporary = destination <> ".download"
      Mix.shell().info("Downloading #{artifact.filename}")

      try do
        download!(artifact.url, temporary)
        verify_checksum!(temporary, artifact.sha256)
        File.rename!(temporary, destination)
      after
        File.rm(temporary)
      end
    end)

    Mix.shell().info("Installed pinned JVM Clojure to #{install_dir}")
  end

  defp download!(url, destination) do
    uri = URI.parse(url)

    unless uri.scheme == "https" and uri.host == "repo1.maven.org" and uri.port in [nil, 443] do
      Mix.raise("Refusing to download JVM Clojure from untrusted URL #{url}")
    end

    args = [
      "--proto",
      "=https",
      "--tlsv1.2",
      "--fail",
      "--silent",
      "--show-error",
      "--output",
      destination,
      url
    ]

    case System.cmd("curl", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> Mix.raise("Clojure download failed (#{status}): #{String.trim(output)}")
    end
  end

  defp verify_checksum!(path, expected) do
    actual =
      path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    unless actual == expected do
      Mix.raise("SHA-256 mismatch for #{Path.basename(path)}")
    end
  end
end
