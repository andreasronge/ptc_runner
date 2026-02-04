# Capability Registry Architecture

> A Verified Capability Store with Dynamic Tool Smithing and Skill Learning

## Executive Summary

The Capability Registry transforms how agents access capabilities. Instead of flooding every agent with dozens of tools (the MCP anti-pattern), the Meta Planner acts as a **Linker** that resolves only the capabilities needed for each mission. This creates a "Context Economy" where worker agents operate with minimal, focused capability sets.

**Two types of capabilities:**
- **Tools** - Executable code (functions the agent *calls*)
- **Skills** - Reusable expertise (prompts that guide *how* the agent reasons)

Key innovations:
- **Planning-time capability resolution** - Meta Planner selects tools AND skills
- **Self-expanding capabilities** - Agents can "smith" new tools or crystallize skills
- **Immune memory** - Trial history prevents repeated failures
- **Regression-proof registration** - Tools must pass all historical tests
- **Cheap expertise capture** - Skills are prompts, not code—easy to create and test

## The Problem: Context Bloat

In traditional MCP-style architectures:

```
Worker Agent Context Window:
├── System prompt (500 tokens)
├── Tool definitions (50 tools × 200 tokens = 10,000 tokens)
├── Conversation history (2,000 tokens)
└── Actual reasoning space (LIMITED)
```

**Result**: 80% of context consumed by irrelevant tools. The agent wastes tokens reasoning about which tool to use instead of solving the problem.

## The Solution: Meta Planner as Linker

```
┌─────────────────────────────────────────────────────────────────┐
│                        Meta Planner                              │
│                                                                  │
│  Mission: "Generate Q4 salary report for EU employees"          │
│                                                                  │
│  1. CAPABILITY EXTRACTION                                        │
│     Needs: [csv_parsing, filtering, salary_calc, formatting]    │
│     Context: [EU, salary, Q4, employees]                        │
│                                                                  │
│  2. REGISTRY QUERY (Discovery)                                   │
│     Tools:                                                       │
│       csv_parsing    → parse_csv_eu (GREEN, 94%)                │
│       filtering      → filter_employees (GREEN, 89%)            │
│       salary_calc    → ❌ MISSING                                │
│       formatting     → format_report (RED, broken)              │
│     Skills:                                                      │
│       context:EU     → european_csv_handling (98% in EU)        │
│       context:salary → salary_privacy_rules (95%)               │
│                                                                  │
│  3. LINK DECISION                                                │
│     Phase 0: Smith salary_calc, Repair format_report            │
│     Phase 1: Execute with 4 tools + 2 skills                    │
│                                                                  │
│  4. WORKER INJECTION                                             │
│     Tools:  [parse_csv_eu, filter_employees,                    │
│              salary_calc, format_report_v2]                     │
│     Skills: [european_csv_handling, salary_privacy_rules]       │
│     Context: 4 tools × 200 + 2 skills × 150 = 1100 tokens       │
│              (vs 10,000 tokens for all capabilities)            │
└─────────────────────────────────────────────────────────────────┘
```

## Core Concepts

### Tools vs Skills

| Aspect | Tool | Skill |
|--------|------|-------|
| **What it is** | Executable code | Knowledge/instructions (prompt) |
| **How it's used** | Agent *calls* it | Agent *knows* it (injected into prompt) |
| **Execution** | Runtime function call | Shapes LLM reasoning |
| **Creation cost** | High (code + tests) | Low (just prompt text) |
| **Example** | `parse_csv(text)` | "European CSVs use semicolons; dates are DD/MM/YYYY" |

**A Skill is expertise, not code.** It makes agents better at using existing tools.

```
Tool (executable):
  (defn parse-csv [text]
    (let [lines (string/split text "\n")] ...))

Skill (expertise):
  "When parsing CSV files:
   - Check for BOM markers in UTF-8 files
   - European CSVs often use semicolons, not commas
   - Quoted fields may contain embedded newlines
   - Empty rows should be skipped, not treated as data"
```

**When to use each:**

| Situation | Create Tool | Create Skill |
|-----------|-------------|--------------|
| New functionality needed | ✓ | |
| Better use of existing tools | | ✓ |
| Algorithm can be codified | ✓ | |
| Guidance is heuristic | | ✓ |
| Needs formal verification | ✓ | |
| Quick expertise capture | | ✓ |

### Capabilities vs Implementations

A **Capability** represents *what* can be done (the interface).
An **Implementation** represents *how* (concrete tool or skill).

```elixir
# One capability, multiple implementations
Capability: "parse_csv"
├── parse_csv_v1        (original, 80% success)
├── parse_csv_v2_quoted (handles quoted fields, 95%)
└── parse_csv_eu        (European dates, 98% in EU context)
```

The registry resolves the best implementation based on **context affinity** - matching mission context tags against implementation success rates.

### Capability Layers

| Layer | Type | Name | Description | Persistence |
|-------|------|------|-------------|-------------|
| 1 | Tool | **Base** | Developer-provided primitives (Elixir functions) | Static |
| 2 | Tool | **Composed** | PTC-Lisp functions combining base tools | Smithed |
| 3 | Skill | **Skill** | Reusable expertise (prompt fragments) | Learned |

**Evolution paths:**

```
Tools:   Base → Composed → (higher-order compositions)
Skills:  Observed patterns → Crystallized expertise

Both can be promoted from successful plan executions.
```

**Composed Tool** - Compiles multi-step execution into a single function call:
```lisp
;; Instead of agent doing 5 tool calls...
(defn extract-employee-data [path]
  (-> (tool/file-read {:path path})
      (parse-csv)
      (filter-active)
      (format-output)))
```

**Skill** - Captures expertise that improves tool usage:
```
"When extracting employee data:
 - Always validate CSV encoding before parsing
 - Filter inactive records early to reduce processing
 - Anonymize PII fields before any aggregation
 - European formats: semicolon delimiters, DD/MM/YYYY dates"
```

### Health States

```
┌─────────┐    tests pass    ┌─────────┐
│ PENDING │ ───────────────► │  GREEN  │ ◄──┐
└─────────┘                  └─────────┘    │
     │                            │         │ tests pass
     │ tests fail                 │ test    │ after fix
     ▼                            │ fails   │
┌─────────┐                       ▼         │
│REJECTED │               ┌─────────────┐   │
└─────────┘               │     RED     │ ──┘
                          │ (quarantine)│
                          └─────────────┘
                                 │
                                 ▼
                          ┌─────────────┐
                          │   FLAKY     │ (use with retry strategy)
                          └─────────────┘
```

## Data Structures

### Registry

```elixir
defmodule PtcRunner.CapabilityRegistry do
  defstruct [
    capabilities: %{},          # capability_id => Capability
    tools: %{},                 # tool_id => ToolEntry
    skills: %{},                # skill_id => Skill
    test_suites: %{},           # tool_id => TestSuite
    history: [],                # Trial outcomes for learning
    health: %{},                # tool_id => :green | :red | :flaky
    promotion_candidates: %{},  # pattern_hash => PromotionCandidate
    archived: %{},              # id => ArchivedEntry
    embeddings: nil             # Optional vector index for semantic search
  ]
end
```

### Capability

```elixir
defmodule PtcRunner.ToolRegistry.Capability do
  defstruct [
    :id,                    # "parse_csv"
    :description,           # "Parse CSV text into structured data"
    :canonical_signature,   # The interface contract
    implementations: [],    # List of ToolEntry ids
    default_impl: nil       # Highest overall success rate
  ]
end
```

### Tool Entry

```elixir
defmodule PtcRunner.CapabilityRegistry.ToolEntry do
  defstruct [
    :id,                    # "parse_csv_v2_quoted"
    :capability_id,         # "parse_csv"
    :name,
    :description,
    :signature,             # "(text: string) -> list<map>"
    :layer,                 # :base | :composed
    :source,                # :developer | :smithed
    :tags,                  # ["csv", "parsing", "quoted-fields"]
    :code,                  # PTC-Lisp source (nil for base tools)
    :function,              # Elixir function (for base tools)
    :dependencies,          # Tool IDs this tool requires
    :examples,              # Input/output examples
    :success_rate,          # Overall success rate
    :context_success,       # %{"quoted-fields" => 0.95, "unicode" => 0.72}
    :supersedes,            # ID of tool this replaces
    :version,
    :created_at,
    :last_linked_at,        # For LRL garbage collection
    :link_count             # Total times linked into a mission
  ]
end
```

### Skill

```elixir
defmodule PtcRunner.CapabilityRegistry.Skill do
  @moduledoc """
  A Skill is reusable expertise captured as a prompt fragment.
  Unlike tools, skills don't execute - they guide agent reasoning.
  """
  defstruct [
    :id,                    # "european_csv_handling"
    :name,                  # "European CSV Handling"
    :description,           # "Expertise for handling EU-format CSV files"
    :prompt,                # The actual instruction text (injected into agent)
    :applies_to,            # Tool IDs this skill enhances (for link-time resolution)
    :tags,                  # ["csv", "european", "formatting"]
    :source,                # :developer | :learned
    :success_rate,          # Overall success rate
    :context_success,       # %{"european" => 0.95} - by context tag
    :model_success,         # %{"claude-sonnet-4" => 0.96} - by model ID
    :version,
    :created_at,
    :last_linked_at,
    :link_count,
    :review_status          # nil | :flagged_for_review | :under_review
  ]
end
```

**Example Skill:**

```elixir
%Skill{
  id: "european_csv_handling",
  name: "European CSV Handling",
  prompt: """
  When working with European CSV files:
  - Use semicolon (;) as the default delimiter, not comma
  - Dates are formatted as DD/MM/YYYY, not MM/DD/YYYY
  - Numbers use comma for decimals: 1.234,56 means 1234.56
  - Check for BOM markers in UTF-8 encoded files
  - Watch for mixed encodings (Latin-1 vs UTF-8)
  """,
  applies_to: ["parse_csv", "validate_csv"],
  tags: ["csv", "european", "i18n"],
  source: :learned,
  success_rate: 0.94,
  context_success: %{"european" => 0.98, "csv" => 0.91}
}
```

### Test Suite

```elixir
defmodule PtcRunner.ToolRegistry.TestSuite do
  defstruct [
    :tool_id,
    cases: [],              # [{input, expected_output, tags}]
    inherited_from: nil,    # Parent tool ID (for repairs)
    created_at: nil,
    last_run: nil,
    last_result: nil        # :green | :red | :flaky
  ]
end
```

## Discovery System

### Multi-Strategy Search

Discovery uses graceful degradation across three strategies:

```
Query: "parse comma separated European data"
         │
         ▼
┌─────────────────────────────────────────┐
│ Strategy 1: Exact Tag Matching          │
│ Extract tags → find tools with overlap  │
│ Fast, precise, may miss synonyms        │
└─────────────────────────────────────────┘
         │ no results?
         ▼
┌─────────────────────────────────────────┐
│ Strategy 2: Fuzzy Text Matching         │
│ String.jaro_distance on name + desc     │
│ No external deps, handles typos         │
└─────────────────────────────────────────┘
         │ no results?
         ▼
┌─────────────────────────────────────────┐
│ Strategy 3: Semantic Search             │
│ Embedding similarity (if available)     │
│ Handles synonyms, concepts              │
└─────────────────────────────────────────┘
```

### Context-Aware Resolution

When multiple implementations exist for a capability, resolution considers:

1. **Base success rate** - Overall historical performance
2. **Context affinity** - Success rate for specific tags matching the mission
3. **Failure penalties** - Known failure patterns in similar contexts

```elixir
def resolve(registry, capability_id, context_tags) do
  capability = get_capability(registry, capability_id)

  capability.implementations
  |> Enum.map(fn impl ->
    base = impl.success_rate

    affinity = context_tags
      |> Enum.map(&Map.get(impl.context_success, &1, 0))
      |> Enum.sum()
      |> Kernel./(max(length(context_tags), 1))

    penalty = context_tags
      |> Enum.count(&(Map.get(impl.context_success, &1, 1.0) < 0.3))
      |> Kernel.*(0.2)

    %{impl: impl, score: base + affinity - penalty}
  end)
  |> Enum.max_by(& &1.score)
  |> Map.get(:impl)
end
```

## Linking System

The Linker resolves and injects **both tools and skills** into worker agents.

### Dual Injection

```
Mission: "Parse EU employee CSV and generate salary report"

Linker Resolution:
─────────────────────────────────────────────────────────────
  Tools discovered:
    parse_csv (Layer 2, composed)
    filter_employees (Layer 2, composed)
    format_report (Layer 2, composed)

  Skills discovered:
    european_csv_handling (context: "EU" → 98% success)
    salary_report_best_practices (context: "salary" → 92% success)
─────────────────────────────────────────────────────────────

Worker Agent Receives:
─────────────────────────────────────────────────────────────
  System Prompt (skills injected):
    "You are a data processing agent.

    ## Expertise

    ### European CSV Handling
    - European CSVs use semicolons as delimiters
    - Dates are DD/MM/YYYY, not MM/DD/YYYY
    - Numbers use comma for decimals: 1.234,56

    ### Salary Report Best Practices
    - Always anonymize before aggregating
    - Round to nearest 100 for privacy
    - Include headcount per band, not individuals"

  Tools (available to call):
    - parse_csv: (text: string) -> list<map>
    - filter_employees: (records: list, criteria: map) -> list
    - format_report: (data: map, template: string) -> string
─────────────────────────────────────────────────────────────

Context savings:
  Tools: 3 × 200 tokens = 600 tokens (vs 10,000 for all tools)
  Skills: 2 × 150 tokens = 300 tokens (targeted expertise)
  Total: 900 tokens (91% reduction)
```

### Transitive Tool Dependencies

When a composed tool depends on other tools, the Linker must inject all dependencies:

```
Requested: [generate_salary_report]

Dependency Tree:
  generate_salary_report (Layer 2, composed)
    ├── parse_csv (Layer 2)
    │     └── string_split (Layer 1, base)
    ├── filter_employees (Layer 2)
    └── format_report (Layer 2)
        └── json_encode (Layer 1, base)

Injection:
  Base tools (Elixir):  [string_split, json_encode]
  Lisp prelude:         [parse_csv, filter_employees, format_report]
  Visible to LLM:       [generate_salary_report]
```

### Link-Time Skill Resolution (applies_to)

When the Linker selects tools, it automatically includes skills that `apply_to` those tools:

```elixir
def link(registry, tool_ids, context_tags, opts \\ []) do
  model_id = Keyword.get(opts, :model_id)

  # 1. Resolve tool dependencies
  all_tools = resolve_dependencies(registry, tool_ids)

  # 2. Find skills that apply to selected tools
  tool_linked_skills =
    registry.skills
    |> Enum.filter(fn {_id, skill} ->
      skill.applies_to
      |> Enum.any?(&(&1 in tool_ids))
    end)
    |> Enum.map(fn {_id, skill} -> skill end)

  # 3. Find skills that match context tags
  context_skills = resolve_skills(registry, context_tags, model_id: model_id)

  # 4. Merge and deduplicate
  all_skills =
    (tool_linked_skills ++ context_skills)
    |> Enum.uniq_by(& &1.id)
    |> filter_by_model_effectiveness(model_id)

  %LinkResult{
    tools: all_tools,
    skills: all_skills,
    lisp_prelude: generate_prelude(all_tools),
    skill_prompt: generate_skill_prompt(all_skills)
  }
end
```

**Example:**

```
Selected tools: [parse_csv, filter_employees]

Registry lookup:
  Skills with applies_to containing "parse_csv":
    → european_csv_handling
    → csv_error_recovery

  Skills with applies_to containing "filter_employees":
    → employee_data_privacy

Context tags: ["EU", "salary"]
  → salary_report_best_practices

Final skill set: [european_csv_handling, csv_error_recovery,
                  employee_data_privacy, salary_report_best_practices]
```

This is **Componentized Engineering** - tools and their associated expertise are linked together automatically.

### Dependency Extraction

```elixir
def extract_dependencies(tool) do
  case tool.code do
    nil -> []  # Base tool
    code ->
      ~r/\(tool\/([a-z0-9_-]+)/
      |> Regex.scan(code)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()
  end
end
```

## Verification System

### Regression-Proof Registration

Tools must pass ALL historical tests before registration:

```elixir
def register_repair(registry, repaired_tool, new_test_cases) do
  # Get ALL tests from the tool being replaced
  historical = get_test_suite(registry, repaired_tool.supersedes)

  # Merge historical + new cases
  full_suite = merge_suites(historical, new_test_cases)

  # Run everything
  case run_full_suite(repaired_tool, full_suite) do
    {:ok, %{failed: []}} ->
      # All pass - register and deprecate old
      {:ok, register_and_deprecate(registry, repaired_tool, full_suite)}

    {:ok, %{failed: regressions}} ->
      # Regressions! Reject the repair
      {:error, {:regressions_detected, regressions}}
  end
end
```

### Test Suite Growth

Test suites are **append-only**. Every production failure becomes a permanent test case:

```elixir
def record_failure_as_test(registry, tool_id, failure) do
  new_case = %TestCase{
    input: failure.input,
    expected: :should_not_crash,
    tags: [:regression, :from_production],
    added_reason: failure.diagnosis
  }

  append_test_case(registry, tool_id, new_case)
end
```

### Pre-flight Checks

Before injecting a tool, run smoke tests:

```elixir
def preflight_check(registry, tool_id) do
  suite = get_test_suite(registry, tool_id)
  smoke_cases = Enum.filter(suite.cases, &(:smoke in &1.tags)) |> Enum.take(3)

  case run_tests(tool_id, smoke_cases) do
    :ok -> :ok
    {:error, failures} ->
      mark_unhealthy(registry, tool_id, failures)
      {:error, {:preflight_failed, failures}}
  end
end
```

### Skill Validation

Skills don't have formal test suites (they're prompts, not code), but they're validated through:

1. **Success rate tracking** - Did missions using this skill succeed?
2. **A/B comparison** - Same mission with/without skill
3. **Context affinity** - Does the skill help in its intended contexts?

```elixir
def evaluate_skill_effectiveness(registry, skill_id) do
  skill = get_skill(registry, skill_id)

  # Compare missions with and without this skill
  with_skill = get_trials_using(registry, skill_id)
  without_skill = get_similar_trials_without(registry, skill_id, skill.tags)

  %{
    with_skill_success_rate: success_rate(with_skill),
    without_skill_success_rate: success_rate(without_skill),
    lift: success_rate(with_skill) - success_rate(without_skill),
    confidence: statistical_significance(with_skill, without_skill)
  }
end
```

A skill with negative or zero lift may be archived or revised.

### Skill Invalidation (Shadowing)

When a tool is repaired to fix an issue that a skill was working around, the skill may become redundant or contradictory.

**Example:**
```
1. parse_csv fails on European semicolons
2. Skill "european_csv_handling" is created to guide agents
3. parse_csv_v2 is smithed with native semicolon support
4. Skill is now redundant (or worse, contradictory)
```

**Solution: Tool-Skill Linking**

```elixir
defmodule PtcRunner.CapabilityRegistry.SkillInvalidation do
  @doc """
  When a tool is repaired/replaced, flag linked skills for review.
  """
  def on_tool_repair(registry, old_tool_id, new_tool_id) do
    # Find skills that apply to the repaired tool
    linked_skills =
      registry.skills
      |> Enum.filter(fn {_id, skill} ->
        old_tool_id in (skill.applies_to || [])
      end)

    # Flag each for review
    for {skill_id, skill} <- linked_skills do
      flag_for_review(registry, skill_id, %{
        reason: :tool_repaired,
        old_tool: old_tool_id,
        new_tool: new_tool_id,
        question: "Does this skill still apply after tool repair?"
      })
    end
  end
end
```

**Review Interface:**

```
Skill Review Required: european_csv_handling
────────────────────────────────────────────
Trigger: Tool repair (parse_csv → parse_csv_v2)

The tool this skill applies to has been repaired.
Please review if the skill is still needed.

Skill prompt:
  "European CSVs use semicolons as delimiters..."

New tool capabilities:
  parse_csv_v2 now auto-detects delimiter (comma, semicolon, tab)

────────────────────────────────────────────
[Keep]     - Skill still provides value
[Archive]  - Tool now handles this natively
[Revise]   - Update skill for new tool behavior
────────────────────────────────────────────
```

### Model-Specific Skill Effectiveness

Skills (prompts) are more sensitive to the underlying model than tools (code). A skill that works for Sonnet might confuse Haiku or behave differently on GPT-4.

```elixir
defmodule PtcRunner.CapabilityRegistry.Skill do
  defstruct [
    # ... existing fields ...
    :success_rate,          # Overall
    :context_success,       # By context tags
    :model_success,         # NEW: By model ID
  ]
end

# Example
%Skill{
  id: "european_csv_handling",
  success_rate: 0.91,
  context_success: %{
    "european" => 0.98,
    "csv" => 0.89
  },
  model_success: %{
    "claude-sonnet-4" => 0.96,
    "claude-haiku" => 0.82,      # Less effective on smaller model
    "gpt-4o" => 0.78             # Different prompting style needed
  }
}
```

**Model-Aware Skill Resolution:**

```elixir
def resolve_skills(registry, context_tags, opts \\ []) do
  model_id = Keyword.get(opts, :model_id)

  registry.skills
  |> Enum.filter(&matches_context?(&1, context_tags))
  |> Enum.map(fn skill ->
    # Adjust score based on model effectiveness
    model_score = get_in(skill.model_success, [model_id]) || skill.success_rate
    %{skill: skill, score: model_score}
  end)
  |> Enum.filter(fn %{score: score} -> score > 0.5 end)  # Exclude ineffective skills
  |> Enum.sort_by(& &1.score, :desc)
end
```

**When to create model-specific skill variants:**

```
Skill: code_review_guidelines
  claude-sonnet-4: 94% success
  claude-haiku: 61% success  ← Consider variant

Action: Create simplified variant for smaller models
  code_review_guidelines_compact (for Haiku)
```

## Tool Smithing

### When to Smith

The Meta Planner smiths new tools when:

1. **Capability missing** - No tool matches the needed capability
2. **All implementations unhealthy** - Existing tools are RED/quarantined
3. **Optimization opportunity** - Multi-step pattern could become a Skill

### Smithing Workflow

```elixir
%Plan{
  agents: %{
    "tool_smith" => %{
      prompt: "Create PTC-Lisp tools. Output working code with tests.",
      tools: ["validate_syntax", "eval_lisp", "get_base_tools"]
    },
    "tool_tester" => %{
      prompt: "Verify tools with edge cases.",
      tools: ["eval_lisp"]
    }
  },
  tasks: [
    %{
      id: "smith_tool",
      agent: "tool_smith",
      input: "Create tool: {{capability_spec}}",
      verification: "(get-in data/result [\"validation\" \"passed\"])"
    },
    %{
      id: "test_tool",
      agent: "tool_tester",
      depends_on: ["smith_tool"],
      input: "Test with edge cases: {{results.smith_tool.code}}",
      verification: "(>= (get data/result \"tests_passed\") 4)"
    },
    %{
      id: "register_tool",
      type: :synthesis_gate,
      depends_on: ["test_tool"],
      # Calls ToolRegistry.register_with_verification
    }
  ]
}
```

### Automatic Signature Synthesis

When a successful plan is promoted to a Skill:

```elixir
def synthesize_from_plan(plan, results) do
  entry_tasks = Plan.entry_tasks(plan)
  exit_tasks = Plan.exit_tasks(plan)

  input_schema = extract_schema(entry_tasks, results, :input)
  output_schema = extract_schema(exit_tasks, results, :output)

  %{
    signature: "(#{to_params(input_schema)}) -> #{to_type(output_schema)}",
    json_schema: %{input: input_schema, output: output_schema},
    examples: extract_examples(results)
  }
end
```

### Skill Promotion (Candidate → Review → Promotion)

Not every successful plan should become a Skill. Most plans are one-off improvisations. Automatic promotion would bloat the registry with hyper-specific tools.

**Promotion Flow:**

```
Plan Succeeds
     │
     ▼
┌─────────────────┐
│ Extract Pattern │  (normalize away mission-specific details)
└─────────────────┘
     │
     ▼
┌─────────────────┐    new pattern    ┌────────────┐
│ Find Candidate? │ ─────────────────►│ Create     │
└─────────────────┘                   │ Candidate  │
     │ exists                         └────────────┘
     ▼
┌─────────────────┐
│ Increment Count │
└─────────────────┘
     │
     ▼ count >= threshold (default: 3)
┌─────────────────┐
│ Flag for Review │
└─────────────────┘
     │
     ▼ human/planner decision
┌─────────────────────────────────────────┐
│ Promote          Reject         Defer   │
│    │               │              │     │
│    ▼               ▼              ▼     │
│ Register Skill   Record Why    Wait     │
│ as Layer 3       (no re-flag)  for more │
└─────────────────────────────────────────┘
```

**Pattern Extraction:**

```elixir
def extract_pattern(plan) do
  %{
    # Structure matters
    agent_count: map_size(plan.agents),
    task_count: length(plan.tasks),
    task_types: plan.tasks |> Enum.map(& &1.type) |> Enum.sort(),
    dependency_shape: compute_dag_shape(plan),

    # Capabilities matter (normalized)
    capabilities_used: extract_capability_ids(plan)

    # Mission-specific details DON'T matter
    # (actual inputs, file paths, etc. are ignored)
  }
  |> hash()
end
```

**Promotion Candidate:**

```elixir
defmodule PtcRunner.ToolRegistry.PromotionCandidate do
  defstruct [
    :pattern_hash,
    :capability_signature,
    occurrences: [],        # [{mission, result, timestamp}]
    status: :candidate,     # :candidate | :flagged | :promoted | :rejected
    rejection_reason: nil
  ]
end
```

**Review Interface:**

```
Promotion Candidate: #a1b2c3
────────────────────────────────────────
Pattern: 3 agents, 5 tasks, fork-join DAG
Capabilities: [csv_parsing, filtering, aggregation]

Occurrences: 4
  • "Q1 salary report" - success (2024-01-15)
  • "Q2 salary report" - success (2024-04-12)
  • "Contractor payments" - success (2024-05-01)
  • "Q3 salary report" - success (2024-07-18)

Synthesized Signature:
  (source: string, filters: map) -> report<{name, amount}>

────────────────────────────────────────
Promotion Options:

[Promote as Tool]
  Name: generate_filtered_report
  Creates: Composed tool (Layer 2, executable code)
  Benefit: Single function call replaces 12 LLM turns
  Cost: Requires test suite, code maintenance

[Promote as Skill]
  Name: filtered_report_workflow
  Creates: Skill (Layer 3, prompt expertise)
  Benefit: Guides agents through the pattern
  Cost: None - just prompt text

[Reject]
  Reason: ________________
  (Prevents re-flagging of similar patterns)

[Defer]
  Wait for more occurrences before deciding
────────────────────────────────────────
```

**When to promote as Tool vs Skill:**

| Factor | Promote as Tool | Promote as Skill |
|--------|-----------------|------------------|
| Pattern is algorithmic | ✓ | |
| Pattern is heuristic/guidance | | ✓ |
| Needs formal verification | ✓ | |
| Quick capture of expertise | | ✓ |
| High execution frequency | ✓ | |
| Domain-specific knowledge | | ✓ |

## Trial History (Immune Memory)

### Recording Outcomes

After each plan execution, record what worked:

```elixir
def record_trial(registry, plan_result) do
  for {task_id, outcome} <- plan_result.outcomes do
    tools = get_tools_used(plan_result.plan, task_id)

    for tool_id <- tools do
      update_statistics(registry, tool_id, %{
        mission_context: plan_result.mission,
        context_tags: plan_result.tags,
        outcome: outcome,
        diagnosis: get_diagnosis(outcome)
      })
    end
  end
end
```

### Learning from History

Discovery uses trial history to:

1. **Boost successful tools** - Higher scores for tools that worked in similar contexts
2. **Warn about failures** - "Tool X has 0% success on missions with 'quoted-fields'"
3. **Trigger repairs** - Consistent failures prompt Meta Planner to smith replacements

## Garbage Collection

### Least Recently Linked (LRL) Strategy

Implementations that haven't been used and don't provide unique value can be archived:

```elixir
def archive_candidates(registry, opts \\ []) do
  mission_threshold = Keyword.get(opts, :mission_threshold, 1000)

  registry.implementations
  |> Enum.filter(fn impl ->
    missions_since_linked(impl) > mission_threshold and
    not has_unique_test_coverage?(registry, impl)
  end)
end

defp has_unique_test_coverage?(registry, impl) do
  # Does this impl pass tests that NO sibling impl passes?
  siblings = get_sibling_implementations(registry, impl.capability_id)
  impl_passes = passing_test_ids(registry, impl)
  sibling_passes =
    siblings
    |> Enum.flat_map(&passing_test_ids(registry, &1))
    |> MapSet.new()

  # Keep if it uniquely covers some tests
  not MapSet.subset?(impl_passes, sibling_passes)
end
```

**Archive vs Delete:**

Archived implementations are moved to cold storage, not deleted. They can be restored if:
- A mission context matches their specialty
- Their unique test cases become relevant again
- Manual review decides to restore them

## Persistence

### Serialization Strategy

Since PTC-Lisp code is text and all data is JSON-serializable, a simple approach works:

```elixir
defmodule PtcRunner.ToolRegistry.Persistence do
  @doc """
  Serialize registry to JSON file.
  Base tool functions are stored as references, not code.
  """
  def persist(registry, path) do
    registry
    |> to_serializable()
    |> Jason.encode!(pretty: true)
    |> File.write!(path)
  end

  def load(path, base_tools) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> from_serializable(base_tools)
  end

  defp to_serializable(registry) do
    %{
      version: "1.0",
      capabilities: registry.capabilities,
      implementations: Map.new(registry.implementations, fn {id, impl} ->
        {id, serialize_impl(impl)}
      end),
      test_suites: registry.test_suites,
      history: Enum.take(registry.history, -10_000),  # Keep last 10k
      promotion_candidates: registry.promotion_candidates
    }
  end

  defp serialize_impl(%{layer: :base} = impl) do
    # Base tools: store reference, not function
    Map.put(impl, :function, {:base_ref, impl.id})
  end
  defp serialize_impl(impl), do: impl
end
```

**Storage Options:**

| Backend | Use Case | Trade-offs |
|---------|----------|------------|
| JSON file | Single-node, simple | Portable, easy debugging |
| DETS | Single-node, larger | Built-in, concurrent reads |
| SQLite | Single-node, queryable | SQL queries, migrations |
| PostgreSQL | Multi-node, production | Scalable, ACID |

For 90% of use cases, JSON or DETS is sufficient.

## MCP Comparison

| Feature | MCP Approach | Capability Registry |
|---------|--------------|---------------------|
| Context usage | High (all tools every turn) | Minimal (mission-specific tools + skills) |
| Tool selection | LLM decides mid-turn | Meta Planner at plan time |
| Expertise capture | None | Skills (reusable prompts) |
| Persistence | Static (server-defined) | Dynamic (smithing + learning) |
| Execution | Remote/external | Local sandbox (PTC-Lisp) |
| Learning | None | Trial history + success rates |
| Verification | None | Test suites + regression checks |
| Dependencies | Manual | Automatic transitive resolution |
| Knowledge reuse | None | Skills compound over time |

## Implementation Phases

### Phase 1: Core Registry ✓
- [x] `CapabilityRegistry` struct and basic CRUD
- [x] `ToolEntry` with layers and health
- [x] `Skill` struct
- [x] Tag-based discovery (tools and skills)
- [x] Base tool registration
- [ ] JSON persistence (`persist/2`, `load/2`)

### Phase 2: Verification
- [ ] `TestSuite` and test case management
- [ ] `register_with_verification/3` (tools only)
- [ ] Regression detection
- [ ] Pre-flight checks

### Phase 3: Discovery ✓
- [x] Fuzzy search with `jaro_distance`
- [x] Context-aware resolution (tools)
- [x] Context-aware skill matching
- [ ] Optional embedding support (pluggable)

### Phase 4: Linking ✓
- [x] Dependency extraction from PTC-Lisp
- [x] Transitive tool resolution
- [x] Skill injection into system prompt
- [x] Topological sorting
- [x] Lisp prelude generation
- [x] PlanRunner/PlanExecutor integration (`:registry`, `:context_tags` options)

### Phase 5: Smithing & Learning
- [ ] Meta Planner smithing workflow (tools)
- [ ] Signature synthesis from plans
- [ ] `PromotionCandidate` tracking
- [ ] Pattern extraction and hashing
- [ ] Dual promotion: Tool vs Skill decision
- [ ] Skill extraction from successful patterns

### Phase 6: Trial History ✓
- [x] Outcome recording (tools and skills)
- [x] Success rate computation
- [x] Context affinity tracking
- [ ] Failure pattern detection

### Phase 7: Maintenance
- [ ] LRL garbage collection (tools and skills)
- [ ] Archive/restore workflow
- [ ] Health check scheduling (tools)
- [ ] Metrics and observability

## API Summary

```elixir
# Aliased for convenience
alias PtcRunner.CapabilityRegistry, as: Registry

# Discovery (tools and skills)
Registry.discover(registry, query, opts)
Registry.search_tools(registry, capability_query)
Registry.search_skills(registry, context_tags)

# Resolution
Registry.resolve_tool(registry, capability_id, context_tags)
Registry.resolve_skills(registry, context_tags)

# Tool Registration
Registry.register_base_tool(registry, tool_entry)
Registry.register_composed_tool(registry, tool_entry, test_suite)
Registry.register_repair(registry, repaired_tool, new_tests)

# Skill Registration
Registry.register_skill(registry, skill)
Registry.update_skill(registry, skill_id, updates)
Registry.flag_skill_for_review(registry, skill_id, reason)
Registry.list_skills_for_review(registry)

# Linking (injects both tools and skills)
Registry.link(registry, tool_ids, context_tags, model_id: model)
Registry.resolve_dependencies(registry, tool_ids)
Registry.on_tool_repair(registry, old_tool_id, new_tool_id)  # Flags linked skills

# Verification (tools only - skills don't have test suites)
Registry.preflight_check(registry, tool_id)
Registry.run_test_suite(registry, tool_id)
Registry.mark_healthy(registry, tool_id)
Registry.mark_unhealthy(registry, tool_id, failures)

# Learning (both tools and skills)
Registry.record_trial(registry, plan_result)
Registry.get_context_warnings(registry, tags)

# Promotion (can promote to tool OR skill)
Registry.track_pattern(registry, plan, result)
Registry.list_promotion_candidates(registry)
Registry.promote_as_tool(registry, pattern_hash, name, opts)
Registry.promote_as_skill(registry, pattern_hash, name, prompt)
Registry.reject_promotion(registry, pattern_hash, reason)

# Garbage Collection
Registry.archive_candidates(registry, opts)
Registry.archive(registry, id)  # Works for tools or skills
Registry.restore(registry, id)
Registry.list_archived(registry)

# Persistence
Registry.persist(registry, path)
Registry.load(path, base_tools)
```

## Design Decisions

### Resolved

| Question | Decision | Rationale |
|----------|----------|-----------|
| **Persistence** | JSON/DETS | PTC-Lisp is text, simple and portable |
| **Garbage collection** | LRL + unique coverage | Archive after 1000 missions if no unique tests |
| **Promotion** | Candidate → Review → Tool OR Skill | Prevents registry bloat, allows choice of capability type |
| **Embedding search** | Optional, fallback to Jaro | Works without ML infrastructure |
| **Skill linking** | Via `applies_to` field | Tools and skills linked at resolution time |
| **Skill invalidation** | Flag on tool repair | Prevents stale/contradictory skills |
| **Model sensitivity** | Track `model_success` per skill | Skills may work differently across models |

### Open Questions

1. **Embedding provider** - If semantic search is needed: OpenAI, local model, or pluggable?
2. **Versioning display** - Semantic versioning or timestamp-based for UI?
3. **Multi-tenancy** - Shared base tools with tenant-specific smithed tools/skills?
4. **Archive storage** - Same format as active, or compressed cold storage?
5. **Promotion threshold** - 3 occurrences default, should this be configurable per-project?
6. **Model-specific variants** - Auto-create simplified skills for smaller models?
7. **Skill conflict resolution** - What if two skills give contradictory guidance?

## The Linker Metaphor

The Capability Registry follows the same pattern as traditional C/C++ linking:

| C/C++ Concept | Capability Registry |
|---------------|---------------------|
| `.o` / `.obj` files | Base Tools (compiled Elixir functions) |
| `.a` / `.lib` static libraries | Composed Tools (PTC-Lisp bundles) |
| `.so` / `.dll` shared libraries | Registry itself (runtime resolution) |
| Header files (`.h`) | Skills (interface/usage guidance) |
| Compiler flags | Context tags (optimization hints) |
| `ld` / Link.exe | The Linker component |
| Symbol resolution | Capability discovery |
| Transitive dependencies | Tool dependency resolution |

**The key insight**: Just as a C linker only includes the object files needed for the final binary (not the entire standard library), the Capability Linker only injects the tools and skills needed for the current mission.

```
Traditional Linking:
  main.o + utils.o + libmath.a → executable

Capability Linking:
  parse_csv + filter_employees + [european_csv_handling] → worker_agent
```

## Terminology

| Term | Definition |
|------|------------|
| **Capability** | Either a tool or a skill |
| **Tool** | Executable code (base or composed) |
| **Skill** | Reusable expertise (prompt fragment) |
| **Base Tool** | Developer-provided Elixir function |
| **Composed Tool** | PTC-Lisp code combining other tools |
| **Linker** | Component that resolves and injects capabilities |
| **Smithing** | Creating new tools through agent workflow |
| **Learning** | Extracting skills from successful patterns |
| **Shadowing** | Skill becoming redundant after tool repair |

## References

- [Meta Planner Architecture](./meta-planner-architecture.md)
- [PTC-Lisp Specification](../ptc-lisp-specification.md)
- [SubAgent Patterns](../guides/subagent-patterns.md)
