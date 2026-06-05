defmodule PtcRunner.Lisp.Prelude.FullPathIntegrationTest do
  @moduledoc """
  THE full-path V1 integration the plan demands (Implementation Notes):
  prelude load -> analyzer -> evaluator -> discovery -> prompt inventory, all
  driven off ONE compiled `%Prelude{}` artifact and the SAME `%Export{}`
  records.

  One `crm` prelude flows through every surface:

    1. compile source into the artifact;
    2. attach it via `Lisp.run(prelude:)` — the analyzer accepts the qualified
       `crm/get-user` call and the evaluator resolves it from the export table;
    3. the wrapped `(tool/call ...)` runs through the (stubbed) ledger exactly
       once and stays recoverable/branchable;
    4. discovery (`ns-publics`, `doc`, `meta`) returns the SAME export and hides
       the private helper;
    5. the prompt-inventory renderer emits the compact `crm/get-user` entry from
       the SAME records — with the private helper absent.
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

  defp stub_tools(agent) do
    %{
      "call" => fn args ->
        Agent.update(agent, fn calls -> [args | calls] end)

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

  test "one prelude flows through load, analyze, eval, discovery, and prompt inventory", %{
    agent: agent,
    prelude: prelude
  } do
    # --- 1+2+3. Load, analyze, eval, ledger (one upstream attempt) ---
    call_program = """
    (def res (crm/get-user "u_1"))
    (if (res :ok)
      (return {:user (res :value)})
      (return {:error (res :reason)}))
    """

    assert {:ok, %Step{} = step} =
             PtcRunner.Lisp.run(call_program, prelude: prelude, tools: stub_tools(agent))

    # The private helper (normalize-id) ran inside the export — proven by the
    # "norm:" prefix on the id — while the recoverable result stayed branchable.
    assert {:__ptc_return__, %{"user" => %{"id" => "norm:u_1", "name" => "Ada"}}} = step.return
    assert length(step.tool_calls) == 1
    assert Agent.get(agent, & &1) |> length() == 1

    # --- 4. Discovery returns the SAME export; private helper is hidden ---
    publics = run_value("(ns-publics 'crm)", prelude)
    assert Map.has_key?(publics, "get-user")
    assert Map.has_key?(publics, "list-users")
    refute Map.has_key?(publics, "normalize-id")

    doc = run_value("(doc 'crm/get-user)", prelude)
    assert doc =~ "crm/get-user"
    assert doc =~ "Return a CRM user by id."

    meta = run_value("(meta 'crm/get-user)", prelude)
    assert meta[:ref] == "crm/get-user"
    assert meta[:namespace] == "crm"
    assert meta[:effect] == :read

    # The private helper is not reachable through discovery (no export record).
    assert {:error, %Step{} = doc_step} =
             PtcRunner.Lisp.run("(doc 'crm/normalize-id)", prelude: prelude)

    assert doc_step.fail.reason == :runtime_error

    # --- 5. Prompt inventory renders the SAME records (compact entry) ---
    inventory = PromptInventory.render(prelude, ledger: step.tool_calls)

    assert inventory =~ "crm/get-user"
    assert inventory =~ "(get-user id)"
    assert inventory =~ "Return a CRM user by id."
    assert inventory =~ "[read]"
    # The :discoverable export is omitted from the inventory but hinted.
    refute inventory =~ "List CRM users."
    assert inventory =~ "ns-publics"
    # The private helper never appears.
    refute inventory =~ "normalize-id"
    # The ledger summary reflects the single tool call made above.
    assert inventory =~ "Tool calls made: 1"
    assert inventory =~ "Tool call errors: 0"

    # The SAME export ref backs all three surfaces (analyzer/eval, discovery,
    # inventory) — no separate registry.
    assert {:ok, export} = Prelude.fetch_export(prelude, "crm/get-user")
    assert export.ref == "crm/get-user"
    assert export.provider_ref == "upstream:crm/get_user"
    assert export.requires == ["upstream:crm/get_user"]
  end

  defp run_value(program, prelude) do
    assert {:ok, %Step{} = step} = PtcRunner.Lisp.run(program, prelude: prelude)
    step.return
  end
end
