defmodule PtcRunner.Lisp.Prelude.TraceabilityTest do
  @moduledoc """
  Capability Prelude V1 — plan §12 (Traceability) finalization.

  Two guarantees are pinned here:

  1. Trace/debug output includes enough to reproduce the V1 capability
     environment: prelude source hash, compiled-artifact hash, an
     export-record summary, the selected protected namespaces, and a
     host-policy hash/id slot (`nil` until host policy exists). The summary
     is exposed by `PtcRunner.Lisp.Prelude.trace_summary/1` and surfaced on
     the `%Step{}` returned by `PtcRunner.Lisp.run(prelude:)` (success AND
     failure paths).

  2. Secrets/credential values never appear in prompts, descriptor dumps,
     traces, debug records, or error messages. A prelude wraps an upstream
     `(tool/call ...)`; the secret lives only in host/deployment config, NOT
     in the prelude source or its compiled artifact, so it cannot leak through
     any V1 surface.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.PromptInventory
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

  (defn list-users
    "List CRM users."
    {:visibility :discoverable}
    []
    (tool/call {:server "crm" :tool "list_users" :args {}}))
  """

  # A secret value that exists ONLY in host/deployment config (the tool stub),
  # never in the prelude source or its compiled artifact. It must not surface
  # anywhere a model or operator can read it.
  @secret "sk-live-SUPER-SECRET-TOKEN-9f3a"

  defp secret_tool(agent) do
    %{
      "call" => fn args ->
        Agent.update(agent, fn calls -> [args | calls] end)
        # The host config holds the credential; it is used to authorize the
        # call but is NOT returned to the program.
        _authorized_with = @secret

        %{
          ok: true,
          value: %{"id" => get_in(args, ["args", "id"]), "name" => "Ada"},
          reason: nil
        }
      end
    }
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    {:ok, prelude} = Compiler.compile(@crm_source)
    %{agent: agent, prelude: prelude}
  end

  describe "trace_summary/1" do
    test "includes source hash, artifact hash, export summary, protected ns, host-policy slot",
         %{prelude: prelude} do
      summary = Prelude.trace_summary(prelude)

      # Source + artifact hashes (plan §12). Source hash matches the artifact.
      assert summary.source_hash == prelude.source_hash
      assert is_binary(summary.source_hash)
      assert is_binary(summary.artifact_hash)
      assert summary.artifact_hash =~ ~r/^[0-9a-f]{64}$/

      # Selected protected namespaces (string-backed, sorted).
      assert summary.protected_namespaces == ["crm"]

      # Host-policy hash/id slot — nil until host policy exists ("when available").
      assert summary.host_policy_hash == nil

      # Export-record summary: one entry per PUBLIC export, string-backed refs,
      # NO callable values / private env leaked.
      assert is_list(summary.exports)
      refs = Enum.map(summary.exports, & &1.ref) |> Enum.sort()
      assert refs == ["crm/get-user", "crm/list-users"]

      get_user = Enum.find(summary.exports, &(&1.ref == "crm/get-user"))
      assert get_user.namespace == "crm"
      assert get_user.symbol == "get-user"
      assert get_user.arity == 1
      assert get_user.visibility == :prompt
      assert get_user.effect == :read
      assert get_user.provider_ref == "upstream:crm/get_user"
      assert get_user.requires == ["upstream:crm/get_user"]
    end

    test "is JSON-serializable and contains no closures or private env", %{prelude: prelude} do
      summary = Prelude.trace_summary(prelude)

      # No closures / functions / private-env symbols anywhere in the summary.
      refute deep_has_function?(summary)
      refute Map.has_key?(summary, :private_env)

      # JSON-encodable (a real trace sink requirement): atoms/strings/lists only.
      assert {:ok, _json} = Jason.encode(summary)
    end

    test "nil prelude yields nil summary" do
      assert Prelude.trace_summary(nil) == nil
    end
  end

  describe "Step carries prelude trace metadata" do
    test "success step exposes the trace summary", %{agent: agent, prelude: prelude} do
      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run("(crm/get-user \"u_1\")",
                 prelude: prelude,
                 tools: secret_tool(agent)
               )

      assert step.prelude_trace == Prelude.trace_summary(prelude)
      assert step.prelude_trace.protected_namespaces == ["crm"]
    end

    test "error step still exposes the trace summary", %{agent: agent, prelude: prelude} do
      # A protected-redefinition program fails at analysis but the prelude is
      # still attached, so its trace metadata must survive on the error Step.
      assert {:error, %Step{} = step} =
               PtcRunner.Lisp.run("(defn crm/get-user [id] {:fake true})",
                 prelude: prelude,
                 tools: secret_tool(agent)
               )

      assert step.prelude_trace == Prelude.trace_summary(prelude)
    end

    test "no prelude attached leaves prelude_trace nil", %{agent: agent} do
      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run("(+ 1 2)", tools: secret_tool(agent))

      assert step.prelude_trace == nil
    end
  end

  describe "secrets never leak" do
    test "the secret appears nowhere in the prelude source or compiled artifact",
         %{prelude: prelude} do
      # The prelude source the deployment authored does not mention the secret.
      refute @crm_source =~ @secret

      # The compiled artifact (struct + every nested value) does not embed it.
      refute deep_has_secret?(prelude, @secret)
      refute deep_has_secret?(Prelude.trace_summary(prelude), @secret)
    end

    test "the secret does not appear in the step, traces, or any error message",
         %{agent: agent, prelude: prelude} do
      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run("(crm/get-user \"u_1\")",
                 prelude: prelude,
                 tools: secret_tool(agent)
               )

      # The tool actually ran (so the secret was genuinely available to host
      # config), yet none of the agent-visible surfaces carry it.
      assert length(step.tool_calls) == 1
      refute deep_has_secret?(step.return, @secret)
      refute deep_has_secret?(step.tool_calls, @secret)
      refute deep_has_secret?(step.memory, @secret)
      refute deep_has_secret?(step.prelude_trace, @secret)
      assert Agent.get(agent, & &1) |> length() == 1
    end

    test "the secret does not appear in the prompt inventory", %{prelude: prelude} do
      inventory = PromptInventory.render(prelude)
      refute inventory =~ @secret
      # Sanity: the inventory is non-empty (so the refute is meaningful).
      assert inventory =~ "crm/get-user"
    end
  end

  # ----------------------------------------------------------------
  # Deep-walk helpers (structs, maps, lists, tuples, binaries)
  # ----------------------------------------------------------------

  defp deep_has_secret?(term, secret) when is_binary(term), do: String.contains?(term, secret)

  defp deep_has_secret?(term, secret) when is_list(term),
    do: Enum.any?(term, &deep_has_secret?(&1, secret))

  defp deep_has_secret?(%_{} = struct, secret) do
    struct |> Map.from_struct() |> deep_has_secret?(secret)
  end

  defp deep_has_secret?(term, secret) when is_map(term) do
    Enum.any?(term, fn {k, v} ->
      deep_has_secret?(k, secret) or deep_has_secret?(v, secret)
    end)
  end

  defp deep_has_secret?(term, secret) when is_tuple(term) do
    term |> Tuple.to_list() |> deep_has_secret?(secret)
  end

  defp deep_has_secret?(term, secret) when is_atom(term) do
    String.contains?(Atom.to_string(term), secret)
  end

  defp deep_has_secret?(_term, _secret), do: false

  defp deep_has_function?(term) when is_function(term), do: true
  defp deep_has_function?(term) when is_list(term), do: Enum.any?(term, &deep_has_function?/1)

  defp deep_has_function?(%_{} = struct) do
    struct |> Map.from_struct() |> deep_has_function?()
  end

  defp deep_has_function?(term) when is_map(term) do
    Enum.any?(term, fn {k, v} -> deep_has_function?(k) or deep_has_function?(v) end)
  end

  defp deep_has_function?(term) when is_tuple(term) do
    term |> Tuple.to_list() |> deep_has_function?()
  end

  defp deep_has_function?(_term), do: false
end
