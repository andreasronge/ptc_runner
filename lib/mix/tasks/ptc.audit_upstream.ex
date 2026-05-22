defmodule Mix.Tasks.Ptc.AuditUpstream do
  @shortdoc "Check audit metadata against local Clojure and Java runtimes"
  @moduledoc """
  Checks that conformance audit rows point at symbols/members that exist in
  local upstream runtimes.

  This is intentionally an existence check, not a semantic conformance test.

      mix ptc.audit_upstream

  The task uses `clj` or `bb` for Clojure namespace vars and a temporary Java
  reflection probe for curated Java compatibility rows.
  """
  use Mix.Task

  alias PtcRunner.Lisp.Registry

  @clojure_audits [
    {"clojure.core", &Registry.clojure_core_audit/0},
    {"clojure.string", &Registry.clojure_string_audit/0},
    {"clojure.set", &Registry.clojure_set_audit/0},
    {"clojure.walk", &Registry.clojure_walk_audit/0}
  ]

  @clojure_core_special_forms MapSet.new(~w(. def do if quote recur set! throw try))

  @java_audits [
    {:java_lang_boolean_audit, "java.lang.Boolean", :static},
    {:java_lang_double_audit, "java.lang.Double", :static},
    {:java_lang_float_audit, "java.lang.Float", :static},
    {:java_lang_integer_audit, "java.lang.Integer", :static},
    {:java_lang_long_audit, "java.lang.Long", :static},
    {:java_lang_string_audit, "java.lang.String", :instance},
    {:java_lang_system_audit, "java.lang.System", :static},
    {:java_time_local_date_audit, "java.time.LocalDate", :static},
    {:java_time_instant_audit, "java.time.Instant", :static},
    {:java_time_duration_audit, "java.time.Duration", :static},
    {:java_time_period_audit, "java.time.Period", :static},
    {:java_util_date_audit, "java.util.Date", :instance}
  ]

  @java_method_overrides %{
    ".isBefore" => [
      {"java.time.LocalDate", :instance, "isBefore"},
      {"java.time.Instant", :instance, "isBefore"}
    ],
    ".isAfter" => [
      {"java.time.LocalDate", :instance, "isAfter"},
      {"java.time.Instant", :instance, "isAfter"}
    ],
    ".getTime" => [{"java.util.Date", :instance, "getTime"}],
    ".before" => [{"java.util.Date", :instance, "before"}],
    ".after" => [{"java.util.Date", :instance, "after"}]
  }

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
        %{failures: [], skipped: ["Clojure checks (no clj or bb executable found)"]}

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
      path = System.find_executable("clj") -> {path, ["-M", "-e"]}
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
        checks = java_checks()

        case run_java_probe(java, checks) do
          {:ok, missing} -> %{failures: missing, skipped: []}
          {:error, reason} -> %{failures: ["Java probe failed: #{reason}"], skipped: []}
        end
    end
  end

  defp java_checks do
    @java_audits
    |> Enum.flat_map(fn {key, class, default_kind} ->
      key
      |> Registry.java_compat_audit()
      |> Enum.flat_map(&java_entry_checks(&1, class, default_kind))
    end)
    |> Enum.uniq()
  end

  defp java_entry_checks(%{name: name}, class, default_kind) do
    case Map.fetch(@java_method_overrides, name) do
      {:ok, checks} ->
        Enum.map(checks, fn {klass, kind, member} -> {klass, kind, member, name} end)

      :error ->
        [{class, java_kind(name, default_kind), java_member_name(name), name}]
    end
  end

  defp java_kind(name, _default_kind) when name in ["java.util.Date."], do: :constructor

  defp java_kind(name, _default_kind) do
    cond do
      String.starts_with?(name, ".") -> :instance
      String.contains?(name, "/") -> :static
      true -> :instance
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
    dir = Path.join(System.tmp_dir!(), "ptc_audit_upstream_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

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

  defp java_probe_source(checks) do
    cases =
      checks
      |> Enum.map_join("\n", fn {class, kind, member, label} ->
        ~s|    check("#{escape_java(class)}", "#{kind}", "#{escape_java(member)}", "#{escape_java(label)}");|
      end)

    """
    import java.lang.reflect.*;

    public class PtcAuditProbe {
      public static void main(String[] args) throws Exception {
    #{cases}
      }

      static void check(String className, String kind, String member, String label) {
        try {
          Class<?> klass = Class.forName(className);
          boolean ok = switch (kind) {
            case "constructor" -> hasPublicConstructor(klass);
            case "static" -> hasPublicStaticMember(klass, member);
            case "instance" -> hasPublicInstanceMethod(klass, member);
            default -> false;
          };

          if (!ok) {
            System.out.println("MISSING " + label + " -> " + className + "." + member);
          }
        } catch (Throwable t) {
          System.out.println("MISSING " + label + " -> " + className + "." + member + " (" + t.getClass().getSimpleName() + ")");
        }
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
    }
    """
  end

  defp escape_java(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
