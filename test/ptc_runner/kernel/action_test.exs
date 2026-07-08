defmodule PtcRunner.Kernel.ActionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Action

  test "accepts exactly one run_ptc_lisp tool call and preserves metadata" do
    response = %{
      content: nil,
      tool_calls: [%{id: "c1", name: "run_ptc_lisp", args: %{"program" => "(return 42)"}}],
      tokens: %{input: 10, output: 3},
      model: "openrouter:deepseek/deepseek-v4-flash",
      provider: "openrouter",
      provider_meta: %{backend: "deepseek"}
    }

    assert %{
             kind: "tool_call",
             program: "(return 42)",
             tokens: %{input: 10, output: 3},
             model: "openrouter:deepseek/deepseek-v4-flash",
             provider: "openrouter",
             provider_meta: %{backend: "deepseek"}
           } = Action.normalize(response)
  end

  test "decodes JSON arguments when the provider returns raw argument text" do
    response = %{
      tool_calls: [
        %{name: "run_ptc_lisp", arguments: Jason.encode!(%{"program" => "(return :ok)"})}
      ]
    }

    assert %{kind: "tool_call", program: "(return :ok)"} = Action.normalize(response)
  end

  test "accepts OpenAI-style nested function tool calls" do
    response = %{
      tool_calls: [
        %{
          id: "call_1",
          function: %{
            name: "run_ptc_lisp",
            arguments: Jason.encode!(%{"program" => "(return 99)"})
          }
        }
      ]
    }

    assert %{kind: "tool_call", program: "(return 99)"} = Action.normalize(response)
  end

  test "malformed or ambiguous responses fail closed" do
    oversized = String.duplicate("x", 11)

    cases = [
      {"free text", "(return 1)", "free_text_response"},
      {"assistant text plus tool", %{content: "Here", tool_calls: [valid_call()]},
       "assistant_text_with_tool_call"},
      {"missing tool call", %{content: nil}, "missing_tool_call"},
      {"multiple calls", %{tool_calls: [valid_call(), valid_call()]}, "multiple_tool_calls"},
      {"wrong tool", %{tool_calls: [%{name: "lisp_eval", args: %{"program" => "(return 1)"}}]},
       "wrong_tool_name"},
      {"wrong nested tool", %{tool_calls: [%{function: %{name: "lisp_eval", arguments: "{"}}]},
       "wrong_tool_name"},
      {"invalid json", %{tool_calls: [%{name: "run_ptc_lisp", arguments: "{"}]},
       "invalid_json_arguments"},
      {"non-map args", %{tool_calls: [%{name: "run_ptc_lisp", arguments: "[1]"}]},
       "decoded_non_map_arguments"},
      {"missing program", %{tool_calls: [%{name: "run_ptc_lisp", args: %{}}]},
       "extra_or_missing_arguments"},
      {"empty program", %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => " "}}]},
       "program_empty"},
      {"non-string program", %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => 1}}]},
       "program_not_string"},
      {"extra commentary",
       %{
         tool_calls: [
           %{name: "run_ptc_lisp", args: %{"program" => "(return 1)", "commentary" => "x"}}
         ]
       }, "extra_or_missing_arguments"},
      {"oversized program",
       %{tool_calls: [%{name: "run_ptc_lisp", args: %{"program" => oversized}}]},
       "program_too_large"}
    ]

    for {label, response, reason} <- cases do
      assert %{kind: "protocol_error", reason: ^reason} =
               Action.normalize(response, max_program_bytes: 10),
             label
    end
  end

  defp valid_call, do: %{name: "run_ptc_lisp", args: %{"program" => "(return 1)"}}
end
