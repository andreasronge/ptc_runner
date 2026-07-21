defmodule PtcRunner.Lisp.Java.Oracle.ClojureRuntime do
  @moduledoc false

  alias PtcRunner.Lisp.Java.Oracle.Config

  @artifact_root "https://repo1.maven.org/maven2/org/clojure"
  @artifacts [
    %{
      name: :clojure,
      version: "1.12.5",
      sha256: "dfdee131460216a84fef22e537bb0d0579965f8f70338d748323dff26f8e5a8b"
    },
    %{
      name: :spec_alpha,
      artifact: "spec.alpha",
      version: "0.5.238",
      sha256: "94cd99b6ea639641f37af4860a643b6ed399ee5a8be5d717cff0b663c8d75077"
    },
    %{
      name: :core_specs_alpha,
      artifact: "core.specs.alpha",
      version: "0.4.74",
      sha256: "eb73ac08cf49ba840c88ba67beef11336ca554333d9408808d78946e0feb9ddb"
    }
  ]
  @artifacts Enum.map(@artifacts, fn artifact ->
               artifact_name = Map.get(artifact, :artifact, Atom.to_string(artifact.name))
               version = artifact.version

               Map.merge(artifact, %{
                 artifact: artifact_name,
                 filename: "#{artifact_name}-#{version}.jar",
                 url:
                   "#{@artifact_root}/#{artifact_name}/#{version}/#{artifact_name}-#{version}.jar"
               })
             end)

  if Enum.find(@artifacts, &(&1.name == :clojure)).version != Config.versions().clojure do
    raise "Clojure oracle artifact version must match priv/java_oracle_versions.exs"
  end

  @doc false
  def artifacts, do: @artifacts

  @doc false
  def install_dir do
    Path.join(["_build", "tools", "jvm_clojure", Config.versions().clojure])
  end

  @doc false
  def installed? do
    Enum.all?(@artifacts, fn artifact ->
      path = Path.join(install_dir(), artifact.filename)

      case File.read(path) do
        {:ok, bytes} -> sha256(bytes) == artifact.sha256
        {:error, _reason} -> false
      end
    end)
  end

  @doc false
  def classpath do
    separator = if match?({:win32, _}, :os.type()), do: ";", else: ":"

    Enum.map_join(@artifacts, separator, &Path.expand(Path.join(install_dir(), &1.filename)))
  end

  defp sha256(bytes), do: bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
