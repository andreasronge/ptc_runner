defmodule Mix.Tasks.Ptc.JavaFixtures do
  @shortdoc "Verify or regenerate pinned Java interop fixtures"
  @moduledoc """
  Runs the authoritative pinned JVM Clojure oracle and verifies its typed
  checked-in fixture baseline.

      mix ptc.java_fixtures --oracle jvm --check
      mix ptc.java_fixtures --oracle jvm --write

  Install the pinned Clojure jars first with `mix ptc.install_clojure` and use
  the Java version pinned in `mise.toml`.
  """

  use Mix.Task

  alias PtcRunner.Lisp.Java.Oracle.Config
  alias PtcRunner.Lisp.Java.Oracle.Fixtures
  alias PtcRunner.Lisp.Java.Oracle.Runner

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _remaining, invalid} =
      OptionParser.parse(args,
        strict: [oracle: :string, check: :boolean, write: :boolean],
        aliases: [o: :oracle]
      )

    unless invalid == [], do: Mix.raise("Invalid options: #{inspect(invalid)}")

    unless Keyword.get(opts, :oracle, "jvm") == "jvm",
      do: Mix.raise("Fixtures require --oracle jvm")

    mode = fixture_mode(opts)

    case Runner.run(:jvm, :implemented) do
      {:ok, result} -> persist_or_check!(baseline_content(result), mode)
      {:error, reason} -> Mix.raise("Java fixture oracle failed: #{inspect(reason)}")
    end
  end

  defp fixture_mode(opts) do
    case {Keyword.get(opts, :check, false), Keyword.get(opts, :write, false)} do
      {true, false} -> :check
      {false, true} -> :write
      {false, false} -> :check
      {true, true} -> Mix.raise("Choose only one of --check or --write")
    end
  end

  defp persist_or_check!(content, :write) do
    path = source_baseline_path!()
    File.write!(path, content)
    Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
  end

  defp persist_or_check!(content, :check) do
    case File.read(Fixtures.baseline_path()) do
      {:ok, ^content} -> Mix.shell().info("Verified #{Fixtures.baseline_path()}")
      {:ok, _stale} -> Mix.raise("Generated Java oracle baseline is stale")
      {:error, reason} -> Mix.raise("Cannot read Java oracle baseline: #{inspect(reason)}")
    end
  end

  defp source_baseline_path! do
    project_file = Mix.Project.project_file()
    project_root = Path.dirname(project_file)

    unless Mix.Project.config()[:app] == :ptc_runner and
             File.regular?(Path.join(project_root, "priv/java_interop.exs")) do
      Mix.raise("--write is available only from the PtcRunner source checkout")
    end

    Path.join(project_root, Fixtures.baseline_resource())
  end

  defp baseline_content(result) do
    versions = Config.versions()
    environment = Config.environment()

    outcomes =
      Enum.map(result.outcomes, fn outcome ->
        Jason.OrderedObject.new(
          case_id: outcome.case_id,
          overload_id: outcome.overload_id,
          descriptor: outcome.descriptor,
          expected:
            Jason.OrderedObject.new(
              status: Atom.to_string(outcome.expected.status),
              type: Atom.to_string(outcome.expected.type),
              value: outcome.expected.value
            )
        )
      end)

    document =
      Jason.OrderedObject.new(
        versions:
          Jason.OrderedObject.new(
            java:
              Jason.OrderedObject.new(
                distribution: versions.java.distribution,
                vendor: versions.java.vendor,
                feature: versions.java.feature,
                runtime: versions.java.runtime,
                setup_java: versions.java.setup_java,
                mise: versions.java.mise
              ),
            clojure: versions.clojure,
            babashka: versions.babashka
          ),
        environment:
          Jason.OrderedObject.new(
            locale: environment.locale,
            timezone: environment.timezone
          ),
        provenance:
          Jason.OrderedObject.new(
            oracle: "JVM Clojure exact-descriptor reflection adapter",
            command:
              "java -Duser.language=en -Duser.country=US -Duser.timezone=UTC -cp <pinned-jars> clojure.main <bounded-source>",
            java_runtime_version: result.java_runtime_version,
            java_vendor: result.java_vendor,
            clojure_version: result.clojure_version,
            locale: result.locale,
            timezone: result.timezone
          ),
        outcomes: outcomes
      )

    Jason.encode!(document, pretty: true) <> "\n"
  end
end
