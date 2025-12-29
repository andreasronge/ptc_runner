# SubAgent Implementation Plan

> **Status:** Planning
> **Epic:** (to be created)
> **Spec documents:** specification.md, step.md, lisp-api-updates.md, signature-syntax.md, type-coercion-matrix.md, system-prompt-template.md, parallel-trace-design.md

## Overview

This plan breaks down the SubAgent feature into 8 stages, ordered by architectural dependency. Each stage builds on the previous, enabling incremental delivery and testing.

---

## Stage 1: Core Type System

**Dependency:** None

| REQ ID | Summary | Spec Reference | Target Files |
|--------|---------|----------------|--------------|
| CORE-01 | Define Step struct | step.md | lib/ptc_runner/step.ex |
| CORE-02 | Define fail type | step.md#fail | lib/ptc_runner/step.ex |
| CORE-03 | Define usage type | step.md#usage | lib/ptc_runner/step.ex |
| CORE-04 | Define Tool struct for normalization | lisp-api-updates.md#tool-registration | lib/ptc_runner/tool.ex |
| CORE-05 | Implement signature parser | signature-syntax.md | lib/ptc_runner/sub_agent/signature/parser.ex |
| CORE-06 | Implement signature validator | signature-syntax.md#validation-behavior | lib/ptc_runner/sub_agent/signature/validator.ex |
| CORE-07 | Implement type coercion | type-coercion-matrix.md#coercion-table | lib/ptc_runner/sub_agent/signature/coercion.ex |
| CORE-08 | Implement signature renderer | signature-syntax.md#schema-generation-for-prompts | lib/ptc_runner/sub_agent/signature/renderer.ex |
| CORE-09 | Define all Step error reasons | step.md#error-reasons | lib/ptc_runner/step.ex |
| CORE-10 | Handle special type coercion (DateTime, etc.) | type-coercion-matrix.md#special-types | lib/ptc_runner/sub_agent/signature/coercion.ex |

---

## Stage 2: Lisp API Updates

**Dependency:** Stage 1

| REQ ID | Summary | Spec Reference | Target Files |
|--------|---------|----------------|--------------|
| LISP-01 | Return Step from Lisp.run/2 | lisp-api-updates.md#return-type-change | lib/ptc_runner/lisp.ex |
| LISP-02 | Return Step on error | lisp-api-updates.md#error-type-change | lib/ptc_runner/lisp.ex |
| LISP-03 | Rename :result to :return in Memory Result Contract | lisp-api-updates.md#memory-result-contract-key-change | lib/ptc_runner/lisp.ex |
| LISP-04 | Add tool format normalization | lisp-api-updates.md#tool-formats | lib/ptc_runner/lisp.ex |
| LISP-05 | Add :signature option to Lisp.run/2 | lisp-api-updates.md#signature-validation | lib/ptc_runner/lisp.ex |
| LISP-06 | Expose usage metrics in Step | lisp-api-updates.md#usage-metrics | lib/ptc_runner/lisp.ex |
| LISP-07 | Extract @spec/@doc from function refs | lisp-api-updates.md#description-extraction | lib/ptc_runner/sub_agent/type_extractor.ex |

---

## Stage 3: SubAgent Core

**Dependency:** Stage 2

| REQ ID | Summary | Spec Reference | Target Files |
|--------|---------|----------------|--------------|
| AGENT-01 | Define SubAgent struct | specification.md#subagentnew1 | lib/ptc_runner/sub_agent.ex |
| AGENT-02 | Implement SubAgent.new/1 | specification.md#subagentnew1 | lib/ptc_runner/sub_agent.ex |
| AGENT-03 | Implement SubAgent.run/2 (basic) | specification.md#subagentrun2 | lib/ptc_runner/sub_agent.ex |
| AGENT-04 | Implement string convenience form | specification.md#subagentrun2 | lib/ptc_runner/sub_agent.ex |
| AGENT-05 | Implement execution mode logic | specification.md#execution-behavior | lib/ptc_runner/sub_agent.ex |
| AGENT-06 | Implement Loop.run/2 | specification.md#looprun2 | lib/ptc_runner/sub_agent/loop.ex |
| AGENT-07 | Implement response parsing | specification.md#response-parsing | lib/ptc_runner/sub_agent/loop.ex |
| AGENT-08 | Implement LLM callback handling | specification.md#llm-callback | lib/ptc_runner/sub_agent/loop.ex |

---

## Stage 4: System Tools & Memory

**Dependency:** Stage 3

| REQ ID | Summary | Spec Reference | Target Files |
|--------|---------|----------------|--------------|
| SYS-01 | Implement return system tool | specification.md#return | lib/ptc_runner/sub_agent/loop.ex |
| SYS-02 | Implement fail system tool | specification.md#fail | lib/ptc_runner/sub_agent/loop.ex |
| SYS-03 | Inject system tools into registry | specification.md#system-tool-implementation | lib/ptc_runner/sub_agent/loop.ex |
| SYS-04 | Validate reserved tool names | specification.md#reserved-names | lib/ptc_runner/sub_agent.ex |
| SYS-05 | Implement memory operations | specification.md#memory-operations | lib/ptc_runner/sub_agent/loop.ex |
| SYS-06 | Enforce memory limits | specification.md#limits | lib/ptc_runner/sub_agent/loop.ex |
| SYS-07 | Enforce nesting depth limit | specification.md#nesting-limits | lib/ptc_runner/sub_agent/loop.ex |
| SYS-08 | Enforce global turn budget | specification.md#nesting-limits | lib/ptc_runner/sub_agent/loop.ex |
| SYS-09 | Implement timeout behavior | specification.md#timeout-behavior | lib/ptc_runner/sub_agent/loop.ex |

---

## Stage 5: Template & Prompt

**Dependency:** Stage 3

| REQ ID | Summary | Spec Reference | Target Files |
|--------|---------|----------------|--------------|
| PROMPT-01 | Implement template expansion | specification.md#templates | lib/ptc_runner/sub_agent/template.ex |
| PROMPT-02 | Validate template placeholders | specification.md#validation | lib/ptc_runner/sub_agent/template.ex |
| PROMPT-03 | Implement ~PROMPT sigil | specification.md#prompt-sigil | lib/ptc_runner/sub_agent/sigils.ex |
| PROMPT-04 | Generate system prompt | system-prompt-template.md | lib/ptc_runner/sub_agent/prompt.ex |
| PROMPT-05 | Generate data inventory section | system-prompt-template.md#section-3-data-inventory | lib/ptc_runner/sub_agent/prompt.ex |
| PROMPT-06 | Generate tool schemas section | system-prompt-template.md#section-4-tool-schemas | lib/ptc_runner/sub_agent/prompt.ex |
| PROMPT-07 | Generate PTC-Lisp reference | system-prompt-template.md#section-5-ptc-lisp-reference | lib/ptc_runner/sub_agent/prompt.ex |
| PROMPT-08 | Implement system_prompt customization | specification.md#system-prompt-customization | lib/ptc_runner/sub_agent/prompt.ex |
| PROMPT-09 | Implement error recovery prompts | system-prompt-template.md#error-recovery-prompts | lib/ptc_runner/sub_agent/prompt.ex |
| PROMPT-10 | Implement prompt_limit truncation | system-prompt-template.md#token-budget-considerations | lib/ptc_runner/sub_agent/prompt.ex |

---

## Stage 6: Tool Integration

**Dependency:** Stage 4, Stage 5

| REQ ID | Summary | Spec Reference | Target Files |
|--------|---------|----------------|--------------|
| TOOL-01 | Normalize all tool formats | specification.md#tool-formats | lib/ptc_runner/sub_agent/tools.ex |
| TOOL-02 | Implement LLMTool struct | specification.md#llmtool | lib/ptc_runner/sub_agent/llm_tool.ex |
| TOOL-03 | Execute LLMTool in loop | specification.md#llmtool | lib/ptc_runner/sub_agent/loop.ex |
| TOOL-04 | Implement SubAgent.as_tool/2 | specification.md#subagentas_tool2 | lib/ptc_runner/sub_agent.ex |
| TOOL-05 | Implement LLM inheritance | specification.md#llm-inheritance | lib/ptc_runner/sub_agent/loop.ex |
| TOOL-06 | Implement llm_registry | specification.md#llm-registry | lib/ptc_runner/sub_agent.ex |
| TOOL-07 | Handle tool_catalog (planning only) | specification.md#tools-vs-tool_catalog | lib/ptc_runner/sub_agent/prompt.ex |
| TOOL-08 | LLM registry error handling | specification.md#llm-registry-error-handling | lib/ptc_runner/sub_agent.ex |
| TOOL-09 | Tool function return handling | specification.md#tool-registration-edge-cases | lib/ptc_runner/sub_agent/loop.ex |

---

## Stage 7: Advanced Features

**Dependency:** Stage 6

| REQ ID | Summary | Spec Reference | Target Files |
|--------|---------|----------------|--------------|
| ADV-01 | Implement run!/2 | specification.md#subagentrun2-and-then2 | lib/ptc_runner/sub_agent.ex |
| ADV-02 | Implement then!/2 | specification.md#subagentrun2-and-then2 | lib/ptc_runner/sub_agent.ex |
| ADV-03 | Auto-chain with Step detection | specification.md#dd-5-auto-chaining-with-step-detection | lib/ptc_runner/sub_agent.ex |
| ADV-14 | Detect and handle chained failures | specification.md#dd-5-auto-chaining-with-step-detection | lib/ptc_runner/sub_agent.ex |
| ADV-04 | Implement SubAgent.compile/2 | specification.md#subagentcompile2 | lib/ptc_runner/sub_agent.ex |
| ADV-05 | Define CompiledAgent struct | specification.md#appendix-compiledagent-struct | lib/ptc_runner/sub_agent/compiled_agent.ex |
| ADV-06 | Implement CompiledAgent.as_tool/1 | specification.md#compiledagent-as-tool | lib/ptc_runner/sub_agent/compiled_agent.ex |
| ADV-07 | Implement preview_prompt/2 | specification.md#prompt-preview | lib/ptc_runner/sub_agent.ex |
| ADV-08 | Implement debug mode | specification.md#debug-mode | lib/ptc_runner/sub_agent.ex |
| ADV-09 | Implement Debug.print_trace/1 | specification.md#debug-output-helper | lib/ptc_runner/sub_agent/debug.ex |
| ADV-10 | Implement trace filtering options | specification.md#filtering-traces | lib/ptc_runner/sub_agent.ex |
| ADV-11 | Implement llm_retry | specification.md#retry-configuration | lib/ptc_runner/sub_agent/loop.ex |
| ADV-12 | Define SubAgentError exception | specification.md#subagentrun2-and-then2 | lib/ptc_runner/sub_agent/error.ex |
| ADV-13 | Implement Debug.print_chain/1 | specification.md#debugging-chained-agents | lib/ptc_runner/sub_agent/debug.ex |

---

## Stage 8: Observability & Telemetry

**Dependency:** Stage 7

| REQ ID | Summary | Spec Reference | Target Files |
|--------|---------|----------------|--------------|
| OBS-01 | Add trace_id, parent_trace_id to Step | parallel-trace-design.md#enhanced-step-struct | lib/ptc_runner/step.ex |
| OBS-02 | Implement Tracer module | parallel-trace-design.md#trace-id-generation | lib/ptc_runner/tracer.ex |
| OBS-03 | Implement immutable trace recording | parallel-trace-design.md#immutable-recording-pattern | lib/ptc_runner/tracer.ex |
| OBS-04 | Implement Tracer.merge_parallel/2 | parallel-trace-design.md#merging-parallel-traces | lib/ptc_runner/tracer.ex |
| OBS-05 | Record nested SubAgent traces | parallel-trace-design.md#nested-trace-aggregation | lib/ptc_runner/tracer.ex |
| OBS-06 | Implement timeline visualization | parallel-trace-design.md#visualization-support | lib/ptc_runner/tracer/timeline.ex |
| OBS-07 | Emit telemetry events | specification.md#telemetry-hooks | lib/ptc_runner/sub_agent/telemetry.ex |
| OBS-08 | Implement observability queries | parallel-trace-design.md#observability-queries | lib/ptc_runner/tracer.ex |
| OBS-09 | Implement Tracer.add_entry/2 | parallel-trace-design.md#immutable-recording-pattern | lib/ptc_runner/tracer.ex |
| OBS-10 | Implement Tracer.finalize/1 | parallel-trace-design.md#immutable-recording-pattern | lib/ptc_runner/tracer.ex |

---

## Coverage Matrix

| Spec Document | Section | REQ ID | Notes |
|---------------|---------|--------|-------|
| **specification.md** | | | |
| | SubAgent.new/1 | AGENT-01, AGENT-02 | |
| | SubAgent.run/2 | AGENT-03, AGENT-04, AGENT-05 | |
| | Execution Behavior | AGENT-05 | |
| | run!/2 and then!/2 | ADV-01, ADV-02, ADV-12 | |
| | SubAgent.as_tool/2 | TOOL-04 | |
| | SubAgentTool struct | TOOL-04 | Wrapper returned by as_tool/2 |
| | SubAgent.compile/2 | ADV-04 | |
| | Chaining Patterns | ADV-02, ADV-03 | |
| | LLM Inheritance | TOOL-05 | |
| | Loop.run/2 | AGENT-06 | |
| | System Tools (return) | SYS-01 | |
| | System Tools (fail) | SYS-02 | |
| | System Tool Implementation | SYS-03 | |
| | Tool Formats | TOOL-01 | |
| | LLMTool | TOOL-02, TOOL-03 | |
| | Reserved Names | SYS-04 | |
| | tools vs tool_catalog | TOOL-07 | |
| | Signatures & Validation | CORE-05, CORE-06 | |
| | Templates | PROMPT-01, PROMPT-02 | |
| | ~PROMPT Sigil | PROMPT-03 | |
| | LLM Callback | AGENT-08 | |
| | llm_input() type | AGENT-08 | Input map to LLM callback |
| | System Prompt Contents | PROMPT-04 | |
| | System Prompt Customization | PROMPT-08 | |
| | Response Parsing | AGENT-07 | |
| | Memory Operations | SYS-05 | |
| | Memory Limits | SYS-06 | |
| | Step.trace Structure | CORE-01 | |
| | Debug Mode | ADV-08 | |
| | Debug.print_trace/1 | ADV-09 | |
| | Debug.print_chain/1 | ADV-13 | |
| | Prompt Preview | ADV-07 | |
| | Telemetry Hooks | OBS-07 | |
| | Filtering Traces | ADV-10 | |
| | LLM Registry | TOOL-06 | |
| | Retry Configuration | ADV-11 | |
| | CompiledAgent Struct | ADV-05 | |
| | CompiledAgent.as_tool | ADV-06 | |
| | SubAgentError exception | ADV-12 | |
| | Design Decisions | - | Informational, no implementation |
| | Edge Cases & Clarifications | | |
| | - Context Handling | ADV-03, ADV-14 | Empty context, failed step chaining |
| | - Tool Registration Edge Cases | TOOL-09 | Return handling, duplicate names |
| | - LLM Registry Error Handling | TOOL-08 | :llm_not_found, :invalid_llm errors |
| | - Timeout Behavior | SYS-09 | Turn vs mission timeout |
| | - Nesting Limits | SYS-07, SYS-08 | Max depth, global turn budget |
| **step.md** | | | |
| | Struct Definition | CORE-01 | |
| | fail type | CORE-02 | |
| | usage type | CORE-03 | |
| | Error Reasons | CORE-02, CORE-09, TOOL-08, SYS-07, SYS-08, SYS-09 | Includes all error atoms |
| | Usage Patterns | - | Documentation only |
| **lisp-api-updates.md** | | | |
| | Memory Result Contract Key Change | LISP-03 | |
| | Return Type Change | LISP-01 | |
| | Error Type Change | LISP-02 | |
| | Tool Registration | CORE-04, LISP-04 | CORE-04: struct, LISP-04: normalization |
| | Description Extraction | LISP-07 | |
| | Signature Validation | LISP-05 | |
| | Usage Metrics | LISP-06 | |
| **signature-syntax.md** | | | |
| | Full Signature Format | CORE-05 | |
| | Type Reference | CORE-05 | |
| | Named Parameters | CORE-05 | |
| | Firewall Convention | CORE-05 | |
| | Validation Behavior | CORE-06 | |
| | Coercion Rules | CORE-07 | |
| | Validation Modes | CORE-06 | |
| | Error Messages | CORE-06 | |
| | Schema Generation | CORE-08 | |
| | Edge Cases | CORE-05, CORE-06 | Signature parsing and validation |
| | Implementation Modules | CORE-05 to CORE-08 | |
| **type-coercion-matrix.md** | | | |
| | Elixir to Signature Mapping | CORE-07 | |
| | Input Coercion Rules | CORE-07 | |
| | Output Validation Rules | CORE-06 | |
| | Special Types (DateTime, etc.) | CORE-10 | |
| | Type Extraction from @spec | LISP-07 | |
| **system-prompt-template.md** | | | |
| | Role & Purpose | PROMPT-04 | |
| | Environment Rules | PROMPT-04 | |
| | Data Inventory | PROMPT-05 | |
| | Tool Schemas | PROMPT-06 | |
| | PTC-Lisp Reference | PROMPT-07 | |
| | Output Format | PROMPT-04 | |
| | Mission Prompt | PROMPT-01 | |
| | Token Budget | PROMPT-10 | |
| | Error Recovery Prompts | PROMPT-09 | |
| **parallel-trace-design.md** | | | |
| | Enhanced trace_entry Type | OBS-01 | |
| | Enhanced Step Struct | OBS-01 | |
| | Trace ID Generation | OBS-02 | |
| | Immutable Recording | OBS-03, OBS-09, OBS-10 | |
| | Tracer.add_entry/2 | OBS-09 | |
| | Tracer.finalize/1 | OBS-10 | |
| | Parallel Execution Pattern | OBS-04 | |
| | Trace Aggregation | OBS-04 | |
| | Nested Trace Aggregation | OBS-05 | |
| | Timeline Visualization | OBS-06 | |
| | Observability Queries | OBS-08 | |
| | Telemetry Integration | OBS-07 | |
| **guides/** | | - | User documentation, no implementation REQs |

---

## Deferred Items

| Spec Document | Section | Reason |
|---------------|---------|--------|
| signature-syntax.md | Enums (v2+) | Future consideration |
| signature-syntax.md | Union Types (v2+) | Future consideration |
| signature-syntax.md | Refinements (v2+) | Future consideration |

---

## References

- [specification.md](specification.md) - SubAgent API reference
- [step.md](step.md) - Step struct specification
- [lisp-api-updates.md](lisp-api-updates.md) - Breaking changes to Lisp API
- [signature-syntax.md](signature-syntax.md) - Signature syntax reference
- [type-coercion-matrix.md](type-coercion-matrix.md) - Type mapping and coercion
- [system-prompt-template.md](system-prompt-template.md) - System prompt structure
- [parallel-trace-design.md](parallel-trace-design.md) - Parallel trace design
