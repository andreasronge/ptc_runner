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

  test "states why named components carry no source", %{tmp_dir: directory} do
    metadata = %{
      "run_id" => "unauthorized-run",
      "workflow_prelude" => %{"component_ids" => ["kernel"], "hash" => "bundle-hash"}
    }

    unrecorded =
      render(directory, %{
        "metadata" => metadata,
        "turns" => %{"items" => []},
        "preludes" => %{
          "available?" => false,
          "status" => 404,
          "reason" => "inspection_run_not_recorded"
        }
      })

    assert unrecorded =~ "Component sources are private evidence."
    assert unrecorded =~ "this run recorded none"
    refute unrecorded =~ "HTTP"

    # A reason the reader cannot resolve by changing a setting is still stated,
    # as the failure it is. Silence reads as "this run had no sources".
    failed =
      render(directory, %{
        "metadata" => metadata,
        "turns" => %{"items" => []},
        "preludes" => %{"available?" => false, "status" => 500, "reason" => "adapter failed"}
      })

    assert failed =~ "Component sources are private evidence."
    assert failed =~ "The Viewer could not read them: adapter failed (HTTP 500)."
    refute failed =~ "ptc-project.json"
    assert failed =~ "kernel"

    # Nothing was withheld from a run that loaded no component.
    componentless =
      render(directory, %{
        "metadata" => %{"run_id" => "bare-run"},
        "turns" => %{"items" => []},
        "preludes" => %{
          "available?" => false,
          "status" => 404,
          "reason" => "inspection_not_configured"
        }
      })

    refute componentless =~ "Component sources are private evidence."
  end

  test "labels the workflow prelude hash as the bundle identity", %{tmp_dir: directory} do
    rendered =
      render(directory, %{
        "metadata" => %{
          "run_id" => "bundle-run",
          "name" => "sha256:name-fingerprint",
          "workflow_prelude" => %{"component_ids" => ["kernel"], "hash" => "bundle-hash"}
        },
        "turns" => %{"items" => []}
      })

    assert rendered =~ "Bundle"
    assert rendered =~ "bundle-hash"
    refute rendered =~ "sha256:name-fingerprint"
  end

  test "renders the bounded terminal cause from run-stopped", %{tmp_dir: directory} do
    rendered =
      render(directory, %{
        "metadata" => %{"run_id" => "turn-limit-run", "status" => "error"},
        "turns" => %{
          "items" => [
            event(1, "run-started", %{}),
            event(2, "run-stopped", %{
              "outcome" => "error",
              "reason" => "explicit_failure",
              "failure_kind" => "turn-limit",
              "limit" => "agent_turns",
              "limit_value" => 2
            })
          ]
        }
      })

    assert rendered =~ "Agent turn limit reached"
    assert rendered =~ "max_turns was 2"
    refute rendered =~ "explicit_failure"
  end

  test "renders a second evaluation fact from live or envelope evidence", %{tmp_dir: directory} do
    rendered =
      render(directory, %{
        "metadata" => %{"run_id" => "eval-evidence-run", "status" => "error"},
        "last_evaluation_error" => %{
          "kind" => "arithmetic_error",
          "message" => "division by zero"
        },
        "turns" => %{
          "items" => [
            event(1, "run-started", %{}),
            event(2, "run-stopped", %{
              "outcome" => "error",
              "reason" => "arithmetic_error",
              "failure_kind" => "evaluation-unavailable"
            })
          ]
        }
      })

    assert rendered =~ "Run stopped"
    assert rendered =~ "evaluation unavailable"
    assert rendered =~ "Evaluation"
    assert rendered =~ "evaluation: arithmetic_error: division by zero"
  end

  test "renders authorized inspection evaluator evidence as distinct facts", %{tmp_dir: directory} do
    rendered =
      render(directory, %{
        "metadata" => %{"run_id" => "inspect-evidence-run", "status" => "error"},
        "execution_errors" => %{
          "items" => [
            %{
              "evaluation_id" => "workflow-eval-1",
              "kind" => "workflow_failed",
              "reason" => "not_callable",
              "details" => %{}
            }
          ]
        },
        "explicit_failure_values" => %{
          "items" => [
            %{
              "evaluation_id" => "workflow-eval-1",
              "value" => nil
            }
          ]
        },
        "turns" => %{
          "items" => [
            event(1, "run-started", %{}),
            event(2, "run-stopped", %{"outcome" => "error", "failure_kind" => "workflow-failed"})
          ]
        }
      })

    assert rendered =~ "Authorized execution error"
    assert rendered =~ "workflow_failed: not_callable"
    assert rendered =~ "Explicit failure value"
    assert rendered =~ "null"
  end

  test "does not invent an evaluation fact without authenticated evidence", %{tmp_dir: directory} do
    rendered =
      render(directory, %{
        "metadata" => %{"run_id" => "no-eval-evidence-run", "status" => "error"},
        "turns" => %{
          "items" => [
            event(1, "run-started", %{}),
            event(2, "run-stopped", %{
              "outcome" => "error",
              "reason" => "arithmetic_error",
              "failure_kind" => "evaluation-unavailable"
            })
          ]
        }
      })

    assert rendered =~ "Run stopped"
    refute rendered =~ "evaluation: arithmetic_error"
  end

  test "counts the errored rows the transcript renders, not the run outcome", %{
    tmp_dir: directory
  } do
    rendered =
      render(directory, %{
        "metadata" => %{"run_id" => "error-count-run", "status" => "error"},
        "turns" => %{
          "items" => [
            event(1, "run-started", %{}),
            event(2, "evaluation-started", %{
              "evaluation_id" => "workflow-evaluation-1",
              "environment" => "workflow"
            }),
            event(3, "capability-started", %{
              "capability_id" => "capability-1",
              "environment" => "workflow",
              "name" => "kernel-mission-model-context"
            }),
            event(4, "capability-stopped", %{
              "capability_id" => "capability-1",
              "environment" => "workflow",
              "name" => "kernel-mission-model-context",
              "status" => "error"
            }),
            event(5, "evaluation-stopped", %{
              "evaluation_id" => "workflow-evaluation-1",
              "environment" => "workflow",
              "status" => "error"
            }),
            event(6, "run-stopped", %{
              "outcome" => "error",
              "reason" => "explicit_failure",
              "failure_kind" => "mission-unavailable"
            })
          ]
        }
      })

    # One errored evaluation row and one errored capability row. `run-stopped`
    # is the status badge, not a third error.
    assert rendered =~
             ~s(<div class="kt-metric kt-metric-error"><strong>2</strong><span>errors</span></div>)

    assert rendered =~ "Run stopped"
    assert rendered =~ "mission unavailable"
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
