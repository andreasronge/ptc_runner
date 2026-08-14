defmodule PtcViewer.KernelTranscriptTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "renders conversation programs, following results, and captured prelude call links", %{
    tmp_dir: directory
  } do
    program = ~S|(do (runs/diagnose "failed-run") (other/uncaptured))|

    data = %{
      "metadata" => %{
        "run_id" => "debugger-run",
        "missions" => %{
          "default" => %{
            "prelude" => %{
              "component_ids" => ["runs"],
              "dependency_indices" => [[]],
              "hash" => "mission-hash"
            }
          }
        }
      },
      "turns" => %{
        "items" => [
          event(1, "evaluation-started", %{
            "evaluation_id" => "mission-evaluation-1",
            "environment" => "mission",
            "mission_name" => "default",
            "program_kind" => "ptc-lisp"
          }),
          event(2, "evaluation-stopped", %{
            "evaluation_id" => "mission-evaluation-1",
            "environment" => "mission",
            "mission_name" => "default",
            "status" => "ok"
          })
        ]
      },
      "conversation" => %{
        "streams" => [
          %{
            "stream_id" => "stream-1",
            "turns" => [
              %{
                "assistant" => %{
                  "tool_calls" => [
                    %{"id" => "call-1", "args" => %{"program" => program}}
                  ]
                },
                "feedback" => [],
                "generated" => [
                  %{
                    "evaluation_id" => "mission-evaluation-1",
                    "environment" => "mission",
                    "mission_name" => "default",
                    "source" => program,
                    "association_ambiguous?" => false,
                    "prelude_calls" => [
                      %{"component_id" => "runs", "ref" => "runs/diagnose"}
                    ]
                  }
                ]
              },
              %{
                "feedback" => [
                  %{"role" => "tool", "tool_call_id" => "call-1", "content" => "diagnosis"}
                ],
                "generated" => []
              }
            ]
          }
        ]
      },
      "preludes" => %{
        "items" => [
          prelude(20, "mission", "default", ~S|(ns runs) (defn diagnose [] "mission")|)
        ]
      }
    }

    rendered = render(directory, data)

    assert rendered =~ "Program source"
    assert rendered =~ "Execution result"
    assert rendered =~ "diagnosis"
    assert rendered =~ "other/uncaptured"
    assert rendered =~ ~s(class="kt-prelude-call")
    assert rendered =~ ~s(>runs/diagnose</a>)
    assert rendered =~ ~s(href="#kt-prelude-20-0-function-64-69-61-67-6e-6f-73-65")
    refute rendered =~ ~s(>other/uncaptured</a>)
  end

  test "keeps captured calls unlinked without authorized prelude source", %{tmp_dir: directory} do
    data = private_program_data(false)
    rendered = render(directory, data)

    assert rendered =~ "runs/diagnose"
    assert rendered =~ "kt-prelude-call-unavailable"
    refute rendered =~ ~s(class="kt-prelude-call" href=)
  end

  test "does not guess a result for an ambiguous generated-source association", %{
    tmp_dir: directory
  } do
    data = private_program_data(true)
    rendered = render(directory, data)

    assert rendered =~ "Program source"
    refute rendered =~ "Execution result"
    refute rendered =~ "ambiguous-result"
  end

  defp private_program_data(ambiguous?) do
    program = ~S|(runs/diagnose "failed-run")|

    %{
      "metadata" => %{},
      "turns" => %{
        "items" => [
          event(1, "evaluation-started", %{
            "evaluation_id" => "evaluation-1",
            "environment" => "workflow"
          })
        ]
      },
      "conversation" => %{
        "streams" => [
          %{
            "turns" => [
              %{
                "assistant" => %{
                  "tool_calls" => [%{"id" => "call-1", "args" => %{"program" => program}}]
                },
                "generated" => [
                  %{
                    "evaluation_id" => "evaluation-1",
                    "environment" => "workflow",
                    "source" => program,
                    "association_ambiguous?" => ambiguous?,
                    "prelude_calls" => [%{"component_id" => "runs", "ref" => "runs/diagnose"}]
                  }
                ]
              },
              %{
                "feedback" => [
                  %{
                    "role" => "tool",
                    "tool_call_id" => "call-1",
                    "content" => "ambiguous-result"
                  }
                ]
              }
            ]
          }
        ]
      }
    }
  end

  defp prelude(sequence, environment, mission_name, source) do
    %{
      "sequence" => sequence,
      "component_id" => "runs",
      "environment" => environment,
      "mission_name" => mission_name,
      "source" => source,
      "source_hash" => "sha256:#{sequence}",
      "source_bytes" => byte_size(source)
    }
  end

  defp event(sequence, type, data) do
    %{
      "schema_version" => 2,
      "run_id" => "debugger-run",
      "trace_id" => "debugger-trace",
      "sequence" => sequence,
      "timestamp" => "2026-08-13T12:00:0#{sequence}Z",
      "type" => type,
      "data" => data
    }
  end

  defp render(directory, data) do
    input = Path.join(directory, "kernel-transcript.json")
    File.write!(input, Jason.encode!(data))

    script = Path.expand("render_kernel_transcript.mjs", __DIR__)
    assert {rendered, 0} = System.cmd("node", [script, input], stderr_to_stdout: true)
    rendered
  end
end
