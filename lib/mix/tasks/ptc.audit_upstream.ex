defmodule Mix.Tasks.Ptc.AuditUpstream do
  @shortdoc "Check audit metadata against local Clojure and Java runtimes"
  @moduledoc """
  Checks that conformance audit rows point at symbols/members that exist in
  local upstream runtimes.

  This is intentionally an existence check, not a semantic conformance test.

      mix ptc.audit_upstream

  The task uses `bb`, `clojure`, or `clj` for Clojure namespace vars and a
  temporary Java reflection probe for curated Java compatibility rows.
  """
  use Mix.Task

  alias PtcRunner.Lisp.Java.Surface
  alias PtcRunner.Lisp.Registry

  @clojure_audits [
    {"clojure.core", &Registry.clojure_core_audit/0},
    {"clojure.string", &Registry.clojure_string_audit/0},
    {"clojure.set", &Registry.clojure_set_audit/0},
    {"clojure.walk", &Registry.clojure_walk_audit/0}
  ]

  @clojure_core_special_forms MapSet.new(~w(. def do if quote recur set! throw try))
  @minimum_java_source_version 11
  @temporary_directory_attempts 10

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    clojure_results = check_clojure()
    java_results = check_java()

    failures = clojure_results.failures ++ java_results.failures
    skipped = clojure_results.skipped ++ java_results.skipped

    Enum.each(skipped, &Mix.shell().info("SKIP #{&1}"))

    if failures == [] do
      Mix.shell().info("✓ Upstream audit checks passed")
    else
      Enum.each(failures, &Mix.shell().error("✗ #{&1}"))
      Mix.raise("Upstream audit checks failed: #{length(failures)} issue(s)")
    end
  end

  defp check_clojure do
    case clojure_runner() do
      nil ->
        %{failures: [], skipped: ["Clojure checks (no bb, clojure, or clj executable found)"]}

      {cmd, args_prefix} ->
        failures =
          Enum.flat_map(@clojure_audits, &check_clojure_namespace(&1, cmd, args_prefix))

        %{failures: failures, skipped: []}
    end
  end

  defp check_clojure_namespace({ns, fetch}, cmd, args_prefix) do
    names = fetch.() |> Enum.map(& &1.name)

    case clojure_existing_vars(cmd, args_prefix, ns) do
      {:ok, existing} ->
        names
        |> Enum.reject(&clojure_name_exists?(ns, &1, existing))
        |> Enum.map(&"#{ns}/#{&1} is in audit metadata but not upstream")

      {:error, reason} ->
        ["#{ns} check failed: #{reason}"]
    end
  end

  defp clojure_name_exists?(ns, name, existing) do
    MapSet.member?(existing, name) or
      (ns == "clojure.core" and MapSet.member?(@clojure_core_special_forms, name))
  end

  defp clojure_runner do
    cond do
      path = System.find_executable("bb") -> {path, ["-e"]}
      path = System.find_executable("clojure") -> {path, ["-e"]}
      path = System.find_executable("clj") -> {path, ["-e"]}
      true -> nil
    end
  end

  defp clojure_existing_vars(cmd, args_prefix, ns) do
    code = """
    (require '#{ns})
    (doseq [v (sort (map name (keys (ns-publics '#{ns}))))]
      (println v))
    """

    case System.cmd(cmd, args_prefix ++ [code], stderr_to_stdout: true) do
      {out, 0} ->
        existing =
          out
          |> String.split("\n", trim: true)
          |> MapSet.new()

        {:ok, existing}

      {out, code} ->
        {:error, "exit #{code}: #{String.trim(out)}"}
    end
  end

  defp check_java do
    case System.find_executable("java") do
      nil ->
        %{failures: [], skipped: ["Java checks (no java executable found)"]}

      java ->
        case System.cmd(java, ["-version"], stderr_to_stdout: true) do
          {output, 0} -> check_java_version(java, output)
          {output, code} -> java_version_failure("exit #{code}: #{String.trim(output)}")
        end
    end
  end

  defp check_java_version(java, output) do
    case java_major_version(output) do
      {:ok, major} when major >= @minimum_java_source_version ->
        case run_java_probe(java, java_checks()) do
          {:ok, missing} -> %{failures: missing, skipped: []}
          {:error, reason} -> %{failures: ["Java probe failed: #{reason}"], skipped: []}
        end

      {:ok, major} ->
        %{
          failures: [],
          skipped: [
            "Java checks (Java #{major} found; source probe requires Java #{@minimum_java_source_version}+)"
          ]
        }

      :error ->
        java_version_failure("unrecognized output: #{String.trim(output)}")
    end
  end

  defp java_version_failure(reason) do
    %{failures: ["Java version check failed: #{reason}"], skipped: []}
  end

  @doc false
  @spec java_major_version(String.t()) :: {:ok, pos_integer()} | :error
  def java_major_version(output) when is_binary(output) do
    case Regex.run(~r/version \"(?:1\.)?([0-9]+)/, output, capture: :all_but_first) do
      [major] -> {:ok, String.to_integer(major)}
      _no_match -> :error
    end
  end

  @doc false
  def java_checks do
    (java_audit_checks() ++ java_descriptor_checks())
    |> Enum.uniq()
  end

  defp java_audit_checks do
    Surface.audit_specs()
    |> Enum.flat_map(fn spec ->
      spec.key
      |> Surface.audit_targets()
      |> Enum.flat_map(&java_entry_checks(&1, spec.namespace, spec.default_kind))
    end)
  end

  defp java_descriptor_checks do
    classes = Map.new(Surface.classes(), &{&1.class_id, &1})
    references = Map.new(Surface.references(), &{&1.reference_id, &1})

    for spec <- Surface.audit_specs(),
        target <- Surface.audit_targets(spec.key),
        target.status == :supported,
        {overload_id, descriptor} <- target.jvm_descriptor_attestations,
        reference = Map.fetch!(references, target.reference_id),
        class = Map.fetch!(classes, reference.class_id) do
      {class.name, reference.kind, reference.member, descriptor, Atom.to_string(overload_id)}
    end
  end

  defp java_entry_checks(%{name: name, upstream: checks}, _class, _default_kind) do
    Enum.map(checks, fn {klass, kind, member} -> {klass, kind, member, nil, name} end)
  end

  defp java_entry_checks(%{name: name}, class, default_kind) do
    [{class, java_kind(name, default_kind), java_member_name(name), nil, name}]
  end

  defp java_kind(name, _default_kind) when name in ["java.util.Date."], do: :constructor

  defp java_kind(name, default_kind) do
    cond do
      String.starts_with?(name, ".") -> :instance
      String.contains?(name, "/") -> :static
      true -> default_kind
    end
  end

  defp java_member_name("java.util.Date."), do: "<init>"

  defp java_member_name(name) do
    name
    |> String.trim_leading(".")
    |> String.split("/", parts: 2)
    |> List.last()
  end

  defp run_java_probe(java, checks) do
    dir = temporary_probe_directory()

    source = Path.join(dir, "PtcAuditProbe.java")
    File.write!(source, java_probe_source(checks))

    try do
      case System.cmd(java, [source], stderr_to_stdout: true) do
        {out, 0} ->
          missing =
            out
            |> String.split("\n", trim: true)
            |> Enum.filter(&String.starts_with?(&1, "MISSING "))
            |> Enum.map(&String.replace_prefix(&1, "MISSING ", ""))

          {:ok, missing}

        {out, code} ->
          {:error, "exit #{code}: #{String.trim(out)}"}
      end
    after
      File.rm_rf(dir)
    end
  end

  @doc false
  @spec temporary_probe_directory() :: Path.t()
  def temporary_probe_directory do
    create_temporary_probe_directory(@temporary_directory_attempts)
  end

  defp create_temporary_probe_directory(0) do
    raise File.Error,
      reason: :eexist,
      action: "create exclusive Java audit temporary directory",
      path: System.tmp_dir!()
  end

  defp create_temporary_probe_directory(attempts_left) do
    suffix = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    dir = Path.join(System.tmp_dir!(), "ptc_audit_upstream_#{suffix}")

    case File.mkdir(dir) do
      :ok -> dir
      {:error, :eexist} -> create_temporary_probe_directory(attempts_left - 1)
      {:error, reason} -> raise File.Error, reason: reason, action: "create directory", path: dir
    end
  end

  defp java_probe_source(checks) do
    cases =
      checks
      |> Enum.map_join("\n", fn {class, kind, member, descriptor, label} ->
        ~s|    check("#{escape_java(class)}", "#{kind}", "#{escape_java(member)}", "#{escape_java(descriptor || "")}", "#{escape_java(label)}");|
      end)

    """
    import java.lang.reflect.*;

    public class PtcAuditProbe {
      public static void main(String[] args) throws Exception {
    #{cases}
      }

      static void check(String className, String kind, String member, String descriptor, String label) {
        try {
          Class<?> klass = Class.forName(className);
          boolean ok = descriptor.isEmpty()
            ? hasPublicMember(klass, kind, member)
            : hasExactPublicMember(klass, kind, member, descriptor);

          if (!ok) {
            System.out.println("MISSING " + label + " -> " + className + "." + member);
          }
        } catch (Throwable t) {
          System.out.println("MISSING " + label + " -> " + className + "." + member + " (" + t.getClass().getSimpleName() + ")");
        }
      }

      static boolean hasPublicMember(Class<?> klass, String kind, String member) {
        if (kind.equals("constructor")) return hasPublicConstructor(klass);
        if (kind.equals("static")) return hasPublicStaticMember(klass, member);
        if (kind.equals("instance")) return hasPublicInstanceMethod(klass, member);
        return false;
      }

      static boolean hasExactPublicMember(Class<?> klass, String kind, String member, String descriptor) {
        if (kind.equals("constructor")) return hasExactConstructor(klass, descriptor);
        if (kind.equals("static")) return hasExactMethod(klass, member, descriptor, true);
        if (kind.equals("instance")) return hasExactMethod(klass, member, descriptor, false);
        if (kind.equals("field")) return hasExactStaticField(klass, member, descriptor);
        return false;
      }

      static boolean hasPublicConstructor(Class<?> klass) {
        return klass.getConstructors().length > 0;
      }

      static boolean hasPublicStaticMember(Class<?> klass, String member) {
        for (Method method : klass.getMethods()) {
          if (method.getName().equals(member) && Modifier.isStatic(method.getModifiers())) return true;
        }

        for (Field field : klass.getFields()) {
          if (field.getName().equals(member) && Modifier.isStatic(field.getModifiers())) return true;
        }

        return false;
      }

      static boolean hasPublicInstanceMethod(Class<?> klass, String member) {
        for (Method method : klass.getMethods()) {
          if (method.getName().equals(member) && !Modifier.isStatic(method.getModifiers())) return true;
        }

        return false;
      }

      static boolean hasExactConstructor(Class<?> klass, String descriptor) {
        for (Constructor<?> constructor : klass.getConstructors()) {
          if (constructorDescriptor(constructor).equals(descriptor)) return true;
        }

        return false;
      }

      static boolean hasExactMethod(
          Class<?> klass,
          String member,
          String descriptor,
          boolean requireStatic
      ) {
        for (Method method : klass.getMethods()) {
          if (method.getName().equals(member)
              && Modifier.isStatic(method.getModifiers()) == requireStatic
              && methodDescriptor(method).equals(descriptor)) return true;
        }

        return false;
      }

      static boolean hasExactStaticField(Class<?> klass, String member, String descriptor) {
        for (Field field : klass.getFields()) {
          if (field.getName().equals(member)
              && Modifier.isStatic(field.getModifiers())
              && typeDescriptor(field.getType()).equals(descriptor)) return true;
        }

        return false;
      }

      static String constructorDescriptor(Constructor<?> constructor) {
        return parameterDescriptor(constructor.getParameterTypes()) + "V";
      }

      static String methodDescriptor(Method method) {
        return parameterDescriptor(method.getParameterTypes()) + typeDescriptor(method.getReturnType());
      }

      static String parameterDescriptor(Class<?>[] parameterTypes) {
        StringBuilder descriptor = new StringBuilder("(");
        for (Class<?> parameterType : parameterTypes) descriptor.append(typeDescriptor(parameterType));
        return descriptor.append(")").toString();
      }

      static String typeDescriptor(Class<?> type) {
        if (type.isArray()) return type.getName().replace('.', '/');
        if (!type.isPrimitive()) return "L" + type.getName().replace('.', '/') + ";";
        if (type == void.class) return "V";
        if (type == boolean.class) return "Z";
        if (type == byte.class) return "B";
        if (type == char.class) return "C";
        if (type == double.class) return "D";
        if (type == float.class) return "F";
        if (type == int.class) return "I";
        if (type == long.class) return "J";
        if (type == short.class) return "S";
        throw new IllegalArgumentException("unknown primitive " + type);
      }
    }
    """
  end

  defp escape_java(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
