defmodule Mix.Tasks.Ptc.JavaConformance do
  @shortdoc "Run pinned Java interop conformance cases"
  @moduledoc """
  Runs structured typed Java interop cases against an executable oracle.

      mix ptc.java_conformance --oracle jvm --subset implemented
      mix ptc.java_conformance --oracle babashka --subset fast
      mix ptc.java_conformance --oracle ptc --subset ptc-only

  JVM Clojure is authoritative for descriptors. Babashka is a fast secondary
  signal and cannot grant overload coverage.
  """

  use Mix.Task

  alias PtcRunner.Lisp.Java.Oracle.Runner

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _remaining, invalid} =
      OptionParser.parse(args, strict: [oracle: :string, subset: :string], aliases: [o: :oracle])

    unless invalid == [], do: Mix.raise("Invalid options: #{inspect(invalid)}")

    oracle = parse_oracle(Keyword.get(opts, :oracle, "jvm"))
    subset = parse_subset(Keyword.get(opts, :subset, default_subset(oracle)))

    case Runner.run(oracle, subset) do
      {:ok, result} ->
        Mix.shell().info(
          "Verified #{length(result.outcomes)} #{oracle} Java interop case(s) in #{subset}"
        )

      {:error, reason} ->
        Mix.raise("Java conformance failed: #{inspect(reason)}")
    end
  end

  defp parse_oracle("jvm"), do: :jvm
  defp parse_oracle("babashka"), do: :babashka
  defp parse_oracle("ptc"), do: :ptc
  defp parse_oracle(value), do: Mix.raise("Unknown Java oracle #{inspect(value)}")

  defp parse_subset("implemented"), do: :implemented
  defp parse_subset("fast"), do: :fast
  defp parse_subset("ptc-only"), do: :ptc_only
  defp parse_subset(value), do: Mix.raise("Unknown Java conformance subset #{inspect(value)}")

  defp default_subset(:jvm), do: "implemented"
  defp default_subset(:babashka), do: "fast"
  defp default_subset(:ptc), do: "ptc-only"
end
