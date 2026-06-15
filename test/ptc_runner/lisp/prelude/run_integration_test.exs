defmodule PtcRunner.Lisp.Prelude.RunIntegrationTest do
  @moduledoc """
  Full-path P2 integration: compile a prelude, attach it via
  `PtcRunner.Lisp.run(prelude:)`, and prove the analyzer accepts qualified
  prelude calls, the evaluator resolves them from the export table, runs the
  wrapped `(tool/call ...)` through the existing ledger exactly once, and keeps
  the recoverable result branchable. Private helpers stay user-invisible, and a
  user `(def get-user ...)` does not collide with `crm/get-user`.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Step

  @paged_data_source File.read!(
                       Path.expand(
                         "../../../../examples/paged_data_prelude/paged_data.clj",
                         __DIR__
                       )
                     )

  # A prelude where the public export `get-user` wraps a literal upstream
  # `(tool/call ...)` and delegates to a PRIVATE helper `normalize-id` that
  # user code must not be able to reach by qualified symbol.
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

  # A stubbed "call" tool standing in for the upstream RunContext/Collector
  # path: it records each invocation in an Agent and returns the recoverable
  # result map shape that `tool/call` yields, so user code can branch on
  # `(res :ok)` / `(res :value)` / `(res :reason)`.
  defp stub_tools(agent) do
    %{
      "call" => fn args ->
        Agent.update(agent, fn calls -> [args | calls] end)

        %{
          ok: true,
          value: %{
            "id" => get_in(args, ["args", "id"]) || get_in(args, [:args, :id]),
            "name" => "Ada"
          },
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

  describe "Load and Call a Prelude Export" do
    test "analyzer accepts crm/get-user and evaluator runs it through the ledger once", %{
      agent: agent,
      prelude: prelude
    } do
      program = """
      (def res (crm/get-user "u_123"))
      (if (res :ok)
        (return {:user (res :value)})
        (return {:error (res :reason)}))
      """

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(program, prelude: prelude, tools: stub_tools(agent))

      # The recoverable tool/call result is branchable by user code. `(return …)`
      # yields the explicit return-signal value (string-keyed at the host
      # boundary), which only the :ok branch produces.
      assert {:__ptc_return__, %{"user" => %{"id" => "norm:u_123", "name" => "Ada"}}} =
               step.return

      # Existing ledger records EXACTLY ONE upstream attempt.
      assert length(step.tool_calls) == 1
      assert Agent.get(agent, & &1) |> length() == 1
    end

    test "recoverable failure result is branchable", %{prelude: prelude} do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      failing_tools = %{
        "call" => fn _args ->
          Agent.update(agent, fn calls -> [:called | calls] end)
          %{ok: false, value: nil, reason: "not_found"}
        end
      }

      program = """
      (def res (crm/get-user "u_404"))
      (if (res :ok)
        (return {:user (res :value)})
        (return {:error (res :reason)}))
      """

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(program, prelude: prelude, tools: failing_tools)

      assert step.return == {:__ptc_return__, %{"error" => "not_found"}}
    end
  end

  describe "Private Helper Is Not User-visible" do
    test "user code cannot call a private prelude helper by qualified symbol", %{
      agent: agent,
      prelude: prelude
    } do
      program = ~S|(crm/normalize-id "u_123")|

      assert {:error, %Step{} = step} =
               PtcRunner.Lisp.run(program, prelude: prelude, tools: stub_tools(agent))

      assert step.fail.reason in [:invalid_form, :unbound_var, :analysis_error]
      # No upstream attempt should have happened.
      assert Agent.get(agent, & &1) == []
    end

    test "the public export can still call the private helper internally", %{
      agent: agent,
      prelude: prelude
    } do
      # Proven indirectly: get-user returns the normalized id, which only
      # normalize-id produces.
      program = ~S|(def res (crm/get-user "abc")) (res :value)|

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(program, prelude: prelude, tools: stub_tools(agent))

      assert step.return["id"] == "norm:abc"
    end
  end

  describe "resolver shadowing" do
    test "user (def get-user ...) does not collide with crm/get-user", %{
      agent: agent,
      prelude: prelude
    } do
      program = """
      (def get-user (fn [id] {:local id}))
      (def local-result (get-user "x"))
      (def crm-result (crm/get-user "y"))
      (return {:local local-result :crm crm-result})
      """

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(program, prelude: prelude, tools: stub_tools(agent))

      assert {:__ptc_return__, %{"local" => local, "crm" => crm}} = step.return
      # Unqualified get-user resolves to the user def (a plain local map)...
      assert local == %{"local" => "x"}
      # ...while qualified crm/get-user resolves to the prelude export, whose
      # recoverable tool/call result wraps the normalized id.
      assert crm[:value]["id"] == "norm:y"
      # Exactly one upstream attempt (the prelude export), none from the local.
      assert Agent.get(agent, & &1) |> length() == 1
    end
  end

  describe "abort-convention export does not leak the prelude env" do
    test "a (fail ...) inside an export keeps user memory and hides private helpers" do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})
      (defn- secret [x] (* x 9))
      (defn boom! "Abort." [_x] (fail {:reason :boom}))
      """

      {:ok, prelude} = Compiler.compile(source)

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run("(def keep 1) (crm/boom! 7)", prelude: prelude)

      # The fail signal propagates as the program's return value...
      assert step.return == {:__ptc_fail__, %{"reason" => "boom"}}
      # ...the user's own binding survives, and the private prelude env (with
      # `secret`/`boom!`) does NOT leak into user memory.
      assert step.memory == %{keep: 1}
    end
  end

  describe "value-position export as a HOF argument" do
    test "a value-position prelude ref resolves its private sibling when applied" do
      source = """
      (ns calc "Pure calc helpers." {:visibility :prompt})
      (defn- bump [x] (+ x 100))
      (defn add-bump "Add 100." [x] (bump x))
      """

      {:ok, prelude} = Compiler.compile(source)

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run("(map calc/add-bump [1 2 3])", prelude: prelude)

      assert step.return == [101, 102, 103]
    end
  end

  describe "Reject Unknown Namespaced Call" do
    test "unknown export in a known prelude namespace is a programmer fault with a hint", %{
      agent: agent,
      prelude: prelude
    } do
      program = ~S|(crm/delete-user "u_123")|

      assert {:error, %Step{} = step} =
               PtcRunner.Lisp.run(program, prelude: prelude, tools: stub_tools(agent))

      assert step.fail.reason in [:invalid_form, :unbound_var, :analysis_error]
      assert step.fail.message =~ "crm"
    end
  end

  describe "Reject Protected Redefinition" do
    test "(defn crm/get-user ...) is a protected-namespace programmer fault", %{
      agent: agent,
      prelude: prelude
    } do
      program = ~S|(defn crm/get-user [id] {:fake true})|

      assert {:error, %Step{} = step} =
               PtcRunner.Lisp.run(program, prelude: prelude, tools: stub_tools(agent))

      assert step.fail.message =~ "crm"
      # Not a generic invalid-qualified-name syntax error: must mention protection.
      assert step.fail.message =~ "protected"
    end

    test "(def crm/x ...) is a protected-namespace programmer fault", %{
      agent: agent,
      prelude: prelude
    } do
      program = ~S|(def crm/x 1)|

      assert {:error, %Step{} = step} =
               PtcRunner.Lisp.run(program, prelude: prelude, tools: stub_tools(agent))

      assert step.fail.message =~ "crm"
      assert step.fail.message =~ "protected"
    end
  end

  describe "no prelude attached keeps existing behavior" do
    test "an unknown namespace still errors without a prelude", %{agent: agent} do
      program = ~S|(crm/get-user "u_123")|

      assert {:error, %Step{} = step} =
               PtcRunner.Lisp.run(program, tools: stub_tools(agent))

      assert step.fail.reason in [:invalid_form, :analysis_error]
    end
  end

  describe "Paged data prelude smoke" do
    setup do
      {:ok, prelude} = Compiler.compile(@paged_data_source)
      {:ok, agent} = Agent.start_link(fn -> [] end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
      %{prelude: prelude, agent: agent}
    end

    test "folds offset pages through a dynamic upstream source", %{
      prelude: prelude,
      agent: agent
    } do
      rows = [
        %{"trip_id" => "t1", "vendor" => "a", "amount" => 10},
        %{"trip_id" => "t2", "vendor" => "a", "amount" => 12},
        %{"trip_id" => "t2", "vendor" => "b", "amount" => 12},
        %{"trip_id" => "t3", "vendor" => "", "amount" => nil},
        %{"trip_id" => "t4", "amount" => 7}
      ]

      tools = paged_stub_tools(agent, rows)

      program = """
      (def source
        {:server "fixture"
         :tool "read_rows"
         :args {}
         :page {:mode :offset
                :limit 2
                :offset-arg :offset
                :limit-arg :limit
                :rows-at [:value "rows"]
                :max-pages 10
                :max-entries 20}})

      (return
        {:sample (paged/sample source 3)
         :presence (paged/field-presence source)
         :vendors (paged/group-count source ["vendor"])
         :collisions (paged/key-collisions source ["trip_id"])})
      """

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(program, prelude: prelude, tools: tools)

      assert step.return ==
               {:__ptc_return__,
                %{
                  "sample" => Enum.take(rows, 3),
                  "presence" => %{
                    "amount" => %{"missing" => 1, "present" => 4},
                    "trip_id" => %{"missing" => 0, "present" => 5},
                    "vendor" => %{"missing" => 2, "present" => 3}
                  },
                  "vendors" => %{
                    "[\"a\"]" => 2,
                    "[\"b\"]" => 1,
                    "[\"\"]" => 1,
                    "[null]" => 1
                  },
                  "collisions" => [["[\"t2\"]", 2]]
                }}

      calls = Agent.get(agent, &Enum.reverse/1)

      assert Enum.map(calls, &get_in(&1, ["args", "offset"])) == [
               0,
               2,
               0,
               2,
               4,
               0,
               2,
               4,
               0,
               2,
               4
             ]

      assert Enum.all?(calls, &(get_in(&1, ["args", "limit"]) == 2))
    end

    test "profile fuses common summaries into one paged scan", %{
      prelude: prelude,
      agent: agent
    } do
      rows = [
        %{
          "trip_id" => "t1",
          "bike_id" => "b1",
          "start_time" => "2026-04-01T10:00:00",
          "duration_min" => 10.0,
          "end_station_id" => "s1"
        },
        %{
          "trip_id" => "t2",
          "bike_id" => "b1",
          "start_time" => "2026-04-01T10:00:00",
          "duration_min" => "11.0"
        },
        %{
          "trip_id" => "t3",
          "bike_id" => "b2",
          "start_time" => "2026-04-01T11:00:00",
          "duration_min" => "12.0",
          "end_station_id" => ""
        },
        %{
          "trip_id" => "t4",
          "bike_id" => "b3",
          "start_time" => "2026-04-01T12:00:00",
          "duration_min" => 13.0,
          "end_station_id" => "s2"
        },
        %{
          "trip_id" => "t5",
          "bike_id" => "b3",
          "start_time" => "2026-04-01T12:00:00",
          "duration_min" => 14.0,
          "end_station_id" => "s3"
        }
      ]

      program = """
      (def source
        {:server "fixture"
         :tool "read_rows"
         :args {}
         :page {:mode :offset
                :limit 2
                :offset-arg :offset
                :limit-arg :limit
                :rows-at [:value "rows"]
                :max-pages 10
                :max-entries 20}})

      (return
        (paged/profile
          source
          {:sample 3
           :presence-fields ["end_station_id"]
           :string-fields ["duration_min"]
           :collision-fields ["bike_id" "start_time"]}))
      """

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(program, prelude: prelude, tools: paged_stub_tools(agent, rows))

      assert step.return ==
               {:__ptc_return__,
                %{
                  "sample" => Enum.take(rows, 3),
                  "presence" => %{
                    "end_station_id" => %{"missing" => 2, "present" => 3}
                  },
                  "string_counts" => %{"duration_min" => 2},
                  "collision_count" => 2
                }}

      calls = Agent.get(agent, &Enum.reverse/1)
      assert Enum.map(calls, &get_in(&1, ["args", "offset"])) == [0, 2, 4]
    end

    test "folds chunk-index pages through a dynamic upstream source", %{
      prelude: prelude,
      agent: agent
    } do
      rows = [
        %{"id" => "a", "kind" => "trip"},
        %{"id" => "b", "kind" => "trip"},
        %{"id" => "c", "kind" => "station"},
        %{"id" => "d", "kind" => "trip"},
        %{"id" => "e", "kind" => "station"}
      ]

      program = """
      (def source
        {:server "fixture"
         :tool "read_chunk"
         :args {}
         :page {:mode :chunk-index
                :limit 2
                :offset-arg :chunkIndex
                :limit-arg :linesPerChunk
                :rows-at [:value "rows"]
                :total-pages-at [:value "totalChunks"]
                :max-pages 10
                :max-entries 20}})

      (return
        (paged/group-count source ["kind"]))
      """

      assert {:ok, %Step{} = step} =
               PtcRunner.Lisp.run(program,
                 prelude: prelude,
                 tools: chunk_index_stub_tools(agent, rows)
               )

      assert step.return ==
               {:__ptc_return__,
                %{
                  "[\"trip\"]" => 3,
                  "[\"station\"]" => 2
                }}

      calls = Agent.get(agent, &Enum.reverse/1)
      assert Enum.map(calls, &get_in(&1, ["args", "chunkIndex"])) == [0, 1, 2]
      assert Enum.all?(calls, &(get_in(&1, ["args", "linesPerChunk"]) == 2))
    end
  end

  defp paged_stub_tools(agent, rows) do
    %{
      "call" => fn args ->
        Agent.update(agent, fn calls -> [args | calls] end)

        offset = get_in(args, ["args", "offset"]) || get_in(args, [:args, :offset]) || 0
        limit = get_in(args, ["args", "limit"]) || get_in(args, [:args, :limit]) || 100

        %{
          ok: true,
          value: %{
            "rows" => rows |> Enum.drop(offset) |> Enum.take(limit),
            "offset" => offset,
            "limit" => limit
          },
          reason: nil
        }
      end
    }
  end

  defp chunk_index_stub_tools(agent, rows) do
    %{
      "call" => fn args ->
        Agent.update(agent, fn calls -> [args | calls] end)

        chunk_index = get_in(args, ["args", "chunkIndex"]) || 0
        lines_per_chunk = get_in(args, ["args", "linesPerChunk"]) || 100
        start_index = if chunk_index == 0, do: 0, else: chunk_index * lines_per_chunk - 1
        chunk_size = if chunk_index == 0, do: lines_per_chunk, else: lines_per_chunk + 1
        returned_rows = rows |> Enum.drop(start_index) |> Enum.take(chunk_size)

        %{
          ok: true,
          value: %{
            "rows" => returned_rows,
            "chunkIndex" => chunk_index,
            "linesPerChunk" => lines_per_chunk,
            "startLine" => start_index + 1,
            "totalChunks" => ceil(length(rows) / lines_per_chunk)
          },
          reason: nil
        }
      end
    }
  end
end
