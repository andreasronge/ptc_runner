defmodule PtcRunner.Step.PublicTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Step
  alias PtcRunner.Step.Public
  alias PtcRunner.Turn

  import PtcRunner.TestSupport.PublicStepAssertions

  test "externalizes native values in public tool-call ledgers" do
    call = %{
      name: "kw",
      args: %{"mode" => %LispKeyword{name: "jsonl"}},
      result: %LispKeyword{name: "toolret"}
    }

    turn =
      Turn.success(1, "(tool/kw {:mode :jsonl})", "(tool/kw {:mode :jsonl})", :ok, %{
        tool_calls: [call],
        memory: %{}
      })

    step = %Step{return: :done, memory: %{}, turns: [turn], tool_calls: [call]}

    public = Public.render(step)
    assert_public_step!(public)

    assert public.tool_calls == [
             %{name: "kw", args: %{"mode" => "jsonl"}, result: "toolret"}
           ]

    assert hd(public.turns).tool_calls == [
             %{name: "kw", args: %{"mode" => "jsonl"}, result: "toolret"}
           ]
  end

  test "externalizes native values in journal and tool cache" do
    step = %Step{
      return: :done,
      memory: %{},
      journal: %{
        "task" => %{"parse" => %LispKeyword{name: "jsonl"}}
      },
      tool_cache: %{
        {"fetch", %{"mode" => %LispKeyword{name: "jsonl"}}} => %{
          result: %{"parse" => %LispKeyword{name: "toolret"}},
          child_step: nil,
          child_trace_id: nil
        }
      }
    }

    public = Public.render(step)
    assert_public_step!(public)

    assert public.journal == %{"task" => %{"parse" => "jsonl"}}

    assert public.tool_cache == %{
             {"fetch", %{"mode" => "jsonl"}} => %{
               result: %{"parse" => "toolret"},
               child_step: nil,
               child_trace_id: nil
             }
           }
  end

  test "externalizes native values in catalog operation ledgers" do
    step = %Step{
      return: :done,
      memory: %{},
      catalog_ops: [
        %{
          operation: :apropos,
          args: [%{"mode" => %LispKeyword{name: "jsonl"}}],
          outcome: :ok,
          reason: nil,
          duration_ms: 1
        }
      ]
    }

    public = Public.render(step)
    assert_public_step!(public)

    assert public.catalog_ops == [
             %{
               operation: :apropos,
               args: [%{"mode" => "jsonl"}],
               outcome: :ok,
               reason: nil,
               duration_ms: 1
             }
           ]
  end

  test "externalizes child steps nested in tool cache" do
    child = %Step{
      return: %LispKeyword{name: "childret"},
      memory: %{"m" => %{"parse" => %LispKeyword{name: "jsonl"}}}
    }

    step = %Step{
      return: :done,
      memory: %{},
      tool_cache: %{
        {"child", %{}} => %{
          result: %LispKeyword{name: "cached"},
          child_step: child,
          child_trace_id: "trace-child"
        }
      }
    }

    public = Public.render(step)
    assert_public_step!(public)

    cached = Map.fetch!(public.tool_cache, {"child", %{}})
    assert cached.result == "cached"
    assert cached.child_step.return == "childret"
    assert cached.child_step.memory == %{"m" => %{"parse" => "jsonl"}}
  end
end
