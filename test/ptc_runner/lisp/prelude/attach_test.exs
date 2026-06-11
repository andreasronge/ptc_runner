defmodule PtcRunner.Lisp.Prelude.AttachTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Attach
  alias PtcRunner.Lisp.Prelude.AttachContext
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Upstream.Eval
  alias PtcRunner.Upstream.Runtime

  # Attach context bundling the upstream runtime (plan P3). Granted-tools
  # validation has its own dedicated suite in tool_requires_test.exs.
  defp ctx(runtime), do: AttachContext.new(runtime: runtime)

  @schema Path.expand(
            "../../../../mcp_server/test/fixtures/openapi/observatory.openapi.json",
            __DIR__
          )

  # ============================================================
  # Fixtures
  # ============================================================

  # A prelude whose single export wraps a LITERAL upstream tool/call, so the
  # compiler infers requires == ["upstream:observatory/list-traces"] (the
  # OpenAPI tool name is kebab-cased by the upstream layer).
  defp literal_prelude(server, tool) do
    source = """
    (ns crm "CRM helpers." {:visibility :prompt})

    (defn list-traces
      "List traces for an org."
      [org-id]
      (tool/call {:server "#{server}" :tool "#{tool}" :args {:org_id org-id}}))
    """

    {:ok, prelude} = Compiler.compile(source)
    prelude
  end

  # A prelude whose export uses DYNAMIC server/tool, so the compiler infers no
  # requires and :unknown effect — attach-time validation must skip it.
  defp dynamic_prelude do
    source = """
    (ns crm "CRM helpers." {:visibility :prompt})

    (defn proxy
      "Dynamic upstream proxy."
      [server tool]
      (tool/call {:server server :tool tool :args {}}))
    """

    {:ok, prelude} = Compiler.compile(source)
    prelude
  end

  defp config(opts \\ []) do
    %{
      "upstreams" => %{
        "observatory" => %{
          "transport" => "openapi",
          "base_url" => "https://observatory.example",
          "schema_file" => @schema,
          "include_operations" => Keyword.get(opts, :operations, ["list_traces", "get_trace"])
        }
      }
    }
  end

  # ============================================================
  # Compile-time inference (the contract attach-time consumes)
  # ============================================================

  describe "compile-time backing inference feeds attach-time requires" do
    test "literal tool/call yields a concrete requires backing id" do
      prelude = literal_prelude("observatory", "list-traces")
      [export] = prelude.exports

      assert export.requires == ["upstream:observatory/list-traces"]
      assert export.provider_ref == "upstream:observatory/list-traces"
      assert export.effect == :read
    end

    test "dynamic server/tool yields :unknown effect and no requires" do
      prelude = dynamic_prelude()
      [export] = prelude.exports

      assert export.requires == []
      assert export.effect == :unknown
      assert export.provider_ref == nil
    end
  end

  # ============================================================
  # Attach-time requires validation against the selected runtime
  # ============================================================

  describe "validate_requires/2 against a configured runtime" do
    setup do
      {:ok, runtime} = Runtime.start_link(config: config())
      on_exit(fn -> Runtime.stop(runtime) end)
      %{runtime: runtime}
    end

    test "passes when the required upstream operation is configured", %{runtime: runtime} do
      prelude = literal_prelude("observatory", "list-traces")
      assert :ok = Attach.validate_requires(prelude, ctx(runtime))
    end

    test "fails naming the operation when the upstream server is not configured", %{
      runtime: runtime
    } do
      prelude = literal_prelude("crm", "get_user")

      assert {:error, err} = Attach.validate_requires(prelude, ctx(runtime))
      assert err.reason == :prelude_attach_failed
      assert err.message =~ "upstream:crm/get_user"
      # names the export that needs it, too
      assert err.ref == "crm/list-traces"
    end

    test "fails naming the operation when the tool is not present on a configured server", %{
      runtime: runtime
    } do
      prelude = literal_prelude("observatory", "delete-everything")

      assert {:error, err} = Attach.validate_requires(prelude, ctx(runtime))
      assert err.reason == :prelude_attach_failed
      assert err.message =~ "upstream:observatory/delete-everything"
    end

    test "dynamic-backed export is skipped (no requires to validate)", %{runtime: runtime} do
      prelude = dynamic_prelude()
      assert :ok = Attach.validate_requires(prelude, ctx(runtime))
    end
  end

  describe "validate_requires/2 with no runtime selected" do
    test "skips upstream requirements when no runtime is configured (plan P3)" do
      # Deliberate change: with no runtime to validate against, upstream
      # requirements are skipped (the granted (tool/call ...) closure plus
      # check_undefined_tools still guard the surface). This preserves direct
      # Lisp.run with a stub tools: map and no configured runtime.
      prelude = literal_prelude("observatory", "list-traces")
      assert :ok = Attach.validate_requires(prelude, ctx(nil))
    end

    test "passes for a dynamic-backed export even with no runtime" do
      prelude = dynamic_prelude()
      assert :ok = Attach.validate_requires(prelude, ctx(nil))
    end

    test "passes for a prelude with no upstream-backed exports" do
      source = """
      (ns util "Pure helpers." {:visibility :prompt})
      (defn add-one [x] (+ x 1))
      """

      {:ok, prelude} = Compiler.compile(source)
      assert :ok = Attach.validate_requires(prelude, ctx(nil))
    end
  end

  # ============================================================
  # attach/2: resolve (source-or-artifact) then validate
  # ============================================================

  describe "attach/2 resolves source-or-artifact then validates requires" do
    setup do
      {:ok, runtime} = Runtime.start_link(config: config())
      on_exit(fn -> Runtime.stop(runtime) end)
      %{runtime: runtime}
    end

    test "compiles prelude SOURCE then validates against the runtime", %{runtime: runtime} do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})
      (defn list-traces "doc" [org-id]
        (tool/call {:server "observatory" :tool "list-traces" :args {:org_id org-id}}))
      """

      assert {:ok, %Prelude{} = prelude} = Attach.attach(source, ctx(runtime))
      assert [%{ref: "crm/list-traces"}] = prelude.exports
    end

    test "passes a precompiled artifact straight through after validation", %{runtime: runtime} do
      prelude = literal_prelude("observatory", "list-traces")
      assert {:ok, ^prelude} = Attach.attach(prelude, ctx(runtime))
    end

    test "surfaces a compile-time validation error from bad source", %{runtime: runtime} do
      # reserved namespace -> compile-time failure, not attach-time
      source = "(ns tool \"nope\" {:visibility :prompt}) (defn evil [x] x)"

      assert {:error, err} = Attach.attach(source, ctx(runtime))
      assert err.reason == :reserved_namespace
    end

    test "surfaces an attach-time requires failure from good source / bad runtime", %{
      runtime: runtime
    } do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})
      (defn get-user "doc" [id]
        (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
      """

      assert {:error, err} = Attach.attach(source, ctx(runtime))
      assert err.reason == :prelude_attach_failed
      assert err.message =~ "upstream:crm/get_user"
    end

    test "raises for genuine programmer misuse (non-prelude struct)", %{runtime: runtime} do
      assert_raise ArgumentError, fn -> Attach.attach(%{not: :a_prelude}, ctx(runtime)) end
    end
  end

  describe "Upstream.Eval threads the runtime into prelude attach (codex round 5 #1)" do
    setup do
      {:ok, runtime} = Runtime.start_link(config: config())
      on_exit(fn -> Runtime.stop(runtime) end)
      %{runtime: runtime}
    end

    test "run_lisp validates requires and fails before running user code", %{runtime: runtime} do
      # Export requires `upstream:crm/get_user`, which is NOT configured on this
      # observatory-only runtime.
      prelude = literal_prelude("crm", "get_user")

      assert {:error, step} =
               Eval.run_lisp(runtime, ~S|(crm/list-traces "org1")|, prelude: prelude)

      assert step.fail.reason == :prelude_attach_failed
      assert step.fail.message =~ "upstream:crm/get_user"
    end

    test "run_lisp does not block when the required upstream is configured", %{runtime: runtime} do
      prelude = literal_prelude("observatory", "list-traces")

      # Attach validation must pass; the subsequent real upstream call may fail
      # (the example host is unreachable), but that is NOT a prelude attach error.
      case Eval.run_lisp(runtime, ~S|(crm/list-traces "org1")|, prelude: prelude) do
        {:ok, _step} -> :ok
        {:error, step} -> refute step.fail.reason == :prelude_attach_failed
      end
    end
  end
end
