defmodule PtcRunner.Lisp.Prelude.ProtectionTest do
  @moduledoc """
  Capability Prelude V1 — first-spike step 4 (P3): protected redefinition
  rejection (END OF SLICE 1).

  This file pins the protection contract at the two boundaries it spans:

    * the ANALYZER (`PtcRunner.Lisp.Analyze.analyze/2`), where a qualified
      `def`/`defn` target into a protected namespace or onto a public export
      must surface a PROTECTION programmer fault that NAMES the protected
      namespace/symbol — not a generic invalid-qualified-name syntax error —
      and where an unknown namespaced call into a known prelude namespace must
      surface an actionable unknown-export fault suggesting discovery forms;
    * the COMPILER (`PtcRunner.Lisp.Prelude.Compiler.compile/1`), which must
      already reject `(ns tool ...)` and every other reserved-namespace
      declaration at compile time (cross-checked against
      `PtcRunner.Lisp.ProtectedNamespaces.reserved/0`).

  End-to-end (`PtcRunner.Lisp.run/2`) protection behavior — the user-facing
  Step shape — is exercised in `run_integration_test.exs`; here we assert the
  analyzer's raw error reason/message so the contract is pinned independently
  of Step mapping, and we additionally prove the protected export is left
  UNCHANGED when a redefinition is rejected.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.ProtectedNamespaces
  alias PtcRunner.Step

  @crm_source """
  (ns crm
    "CRM helpers."
    {:visibility :prompt})

  (defn- normalize-id
    "Trim and lowercase a raw id."
    [raw]
    (str "norm:" raw))

  (defn get-user
    "Return a CRM user by id."
    [id]
    (tool/call {:server "crm" :tool "get_user" :args {:id (normalize-id id)}}))
  """

  setup do
    {:ok, prelude} = Compiler.compile(@crm_source)
    %{prelude: prelude}
  end

  # Analyze a source string against an (optional) attached prelude, returning
  # the analyzer result directly so we can assert on its raw error shape.
  defp analyze(source, prelude \\ nil) do
    {:ok, raw} = Parser.parse(source)
    Analyze.analyze(raw, prelude)
  end

  describe "Reject Protected Redefinition — analyzer" do
    test "(defn crm/get-user ...) names crm AND get-user as a protected public export",
         %{prelude: prelude} do
      assert {:error, {:invalid_form, msg}} =
               analyze("(defn crm/get-user [id] {:fake true})", prelude)

      # Protection fault, not a generic invalid-qualified-name syntax error.
      assert msg =~ "protected"
      # Names the protected namespace.
      assert msg =~ "crm"
      # Names the offending symbol/ref.
      assert msg =~ "crm/get-user"
      # Because crm/get-user IS a public export, the message must say so
      # explicitly — distinguishing "you are redefining a public export" from
      # the plain "this namespace is protected" case. This is the discriminating
      # signal the P3 task requires ("OR the symbol is a public prelude export").
      assert msg =~ "public export"
    end

    test "(def crm/x ...) names crm as a protected namespace (no public export)", %{
      prelude: prelude
    } do
      assert {:error, {:invalid_form, msg}} = analyze("(def crm/x 1)", prelude)

      assert msg =~ "protected"
      assert msg =~ "crm"
      assert msg =~ "crm/x"
      # crm/x is NOT a public export, so it must NOT claim to be one.
      refute msg =~ "public export"
    end

    test "(defn crm/normalize-id ...) onto a PRIVATE helper symbol is still protected",
         %{prelude: prelude} do
      # A private helper has no public export record, but its namespace is
      # protected, so writing crm/<anything> is rejected as a protection fault.
      assert {:error, {:invalid_form, msg}} =
               analyze("(defn crm/normalize-id [x] x)", prelude)

      assert msg =~ "protected"
      assert msg =~ "crm"
    end

    test "reserved namespace targets are protected even with NO prelude attached" do
      for {prog, ns} <- [
            {"(def tool/x 1)", "tool"},
            {"(defn data/foo [x] x)", "data"},
            {"(def budget/x 1)", "budget"},
            {"(def ptc.core/x 1)", "ptc.core"}
          ] do
        assert {:error, {:invalid_form, msg}} = analyze(prog),
               "expected #{prog} to be rejected"

        assert msg =~ "protected", "#{prog}: message must mention protection"
        assert msg =~ ns, "#{prog}: message must name #{ns}"
      end
    end

    test "qualified def OUTSIDE any protected namespace is an explicit unsupported error" do
      # No prelude, non-reserved ns: must be the explicit
      # qualified-definitions-unsupported error, NOT a protection fault and NOT
      # a generic syntax error.
      assert {:error, {:invalid_form, msg}} = analyze("(defn foo/bar [x] x)")

      refute msg =~ "protected"
      assert msg =~ "qualified"
      assert msg =~ "foo/bar"
    end

    test "qualified def into a prelude namespace that is NOT an export is still protected",
         %{prelude: prelude} do
      # crm is a declared prelude namespace, so any qualified def into it is a
      # protection fault even for a brand-new symbol.
      assert {:error, {:invalid_form, msg}} = analyze("(def crm/brand-new 1)", prelude)

      assert msg =~ "protected"
      assert msg =~ "crm"
    end
  end

  describe "Reject Protected Redefinition — the export is left unchanged" do
    test "a rejected (defn crm/get-user ...) does not alter the captured export", %{
      prelude: prelude
    } do
      before_export = Prelude.fetch_export(prelude, "crm/get-user")
      before_env = prelude.private_env

      # Whole program fails at analysis; nothing runs, nothing mutates.
      assert {:error, %Step{}} =
               PtcRunner.Lisp.run(
                 "(defn crm/get-user [id] {:fake true}) (crm/get-user \"u_1\")",
                 prelude: prelude,
                 tools: %{"call" => fn _ -> %{ok: true, value: %{}, reason: nil} end}
               )

      # The compiled artifact the host holds is immutable and untouched.
      assert Prelude.fetch_export(prelude, "crm/get-user") == before_export
      assert prelude.private_env == before_env
    end
  end

  describe "Reject Unknown Namespaced Call — analyzer" do
    test "(crm/delete-user ...) is an unknown-export fault suggesting discovery forms", %{
      prelude: prelude
    } do
      assert {:error, {:invalid_form, msg}} = analyze("(crm/delete-user \"u_123\")", prelude)

      # Names the offending ns/symbol.
      assert msg =~ "crm/delete-user"
      assert msg =~ "crm"
      # Suggests discovery forms.
      assert msg =~ "ns-publics"
      assert msg =~ "apropos"
      # NOT a protection fault — it's an unknown EXPORT, not a write attempt.
      refute msg =~ "protected"
    end

    test "value-position crm/delete-user is also an unknown-export fault", %{prelude: prelude} do
      assert {:error, {:invalid_form, msg}} = analyze("(map crm/delete-user [1 2])", prelude)
      assert msg =~ "ns-publics"
    end
  end

  describe "Compiler cross-check: reserved namespaces rejected at compile time" do
    test "(ns tool ...) is rejected with :reserved_namespace" do
      source = ~S|(ns tool "nope" {:visibility :prompt}) (defn evil [x] x)|

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :reserved_namespace
      assert err.message =~ "tool"
    end

    test "EVERY ProtectedNamespaces.reserved/0 name is rejected at compile time" do
      # Cross-check: the compiler's reserved-namespace gate is driven by the
      # same ProtectedNamespaces table the analyzer's protection check consults,
      # so every reserved name must fail prelude compilation. Pins budget and
      # ptc.core alongside tool/data so the two surfaces cannot drift.
      for ns <- ProtectedNamespaces.reserved() do
        source = "(ns #{ns} \"nope\" {:visibility :prompt})\n(defn evil [x] x)"

        assert {:error, %Prelude.ValidationError{reason: :reserved_namespace} = err} =
                 Compiler.compile(source),
               "expected (ns #{ns} ...) to be rejected as a reserved namespace"

        assert err.message =~ ns
      end
    end

    test "the reserved set is exactly tool/data/budget/ptc.core (V1 lock)" do
      assert ProtectedNamespaces.reserved() ==
               MapSet.new(["tool", "data", "budget", "ptc.core"])
    end
  end
end
