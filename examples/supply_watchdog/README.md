# Supply Watchdog - Tiered Anomaly Detection

This example demonstrates a multi-tier agentic system for detecting anomalies in supply chain inventory data. Each tier processes progressively filtered data, with the filesystem serving as the communication medium between tiers.

## Use Case: Autonomous Data Integrity Agent

Based on real-world requirements for supply chain AI:

> "Deploy an Autonomous Data Integrity Agent that detects and auto-corrects integration errors (e.g., 'doubled stock') to ensure the planning engine consumes clean supply data."

This example shows how to build such a system using SubAgents where:
- **Human describes the problem** in natural language
- **Tier 1 generates detection code** based on the description
- **Tier 2 applies statistical analysis** to score anomalies
- **Tier 3 determines root causes** and proposes fixes

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  HUMAN INPUT                                                    │
│  "Find duplicate inventory entries with identical stock values" │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  TIER 1: Pattern Detector                                       │
│  ─────────────────────────────────────────────────────────────  │
│  Input: Task description + data schema                          │
│  Tools: read_csv, grep, group_by, filter, write_json            │
│  Output: flags/tier1.json (flagged records)                     │
│                                                                 │
│  The LLM generates code to detect patterns described in task    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  TIER 2: Statistical Analyzer                                   │
│  ─────────────────────────────────────────────────────────────  │
│  Input: flags/tier1.json                                        │
│  Tools: read_json, z_score, detect_spikes, rank_by, write_json  │
│  Output: flags/tier2.json (scored anomalies)                    │
│                                                                 │
│  Applies statistical methods to score and rank anomalies        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  TIER 3: Root Cause Reasoner                                    │
│  ─────────────────────────────────────────────────────────────  │
│  Input: flags/tier2.json                                        │
│  Tools: read_json, get_history, get_related, propose_fix        │
│  Output: fixes/proposed.json (corrections with reasoning)       │
│                                                                 │
│  Determines root cause and proposes fixes with confidence       │
└─────────────────────────────────────────────────────────────────┘
```

## Key Design Principles

1. **LLM sees anomalies, not streams** - Tier 1 filters 99% of normal data before LLM reasoning
2. **Filesystem as message bus** - Simple, debuggable, no infrastructure needed
3. **Tools do heavy lifting** - CSV parsing, stats calculations happen outside LLM context
4. **Human describes, agent detects** - Natural language task → generated detection code

## Quick Start

```bash
# Install dependencies
mix deps.get

# Generate test data and run full pipeline
mix run run.exs

# Run with custom task
mix run run.exs --task "find negative stock values"

# Run single-pass detector (simpler)
mix run run.exs --mode detector --task "find stock spikes over 5000"

# Generate data only
mix run run.exs --generate --records 100

# Run with tracing
mix run run.exs --trace

# Validate results against ground truth
mix run run.exs --validate

# Clean up
mix run run.exs --clean
```

## CLI Options

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `--task` | `-t` | Task description for anomaly detection | "find duplicate inventory entries" |
| `--mode` | `-m` | "pipeline" (3-tier) or "detector" (single-pass) | pipeline |
| `--records` | `-r` | Number of normal records to generate | 50 |
| `--seed` | `-s` | Random seed for reproducibility | 42 |
| `--stop-after` | | Stop after tier: "tier1", "tier2", "tier3" | tier3 |
| `--trace` | | Enable execution tracing | false |
| `--generate` | `-g` | Only generate test data | false |
| `--validate` | `-v` | Validate results against ground truth | false |
| `--clean` | `-c` | Clean up generated files | false |

## Anomaly Types

The data generator injects these anomaly types:

| Type | Description | Detection Method |
|------|-------------|------------------|
| `duplicate` | Exact duplicate entries (same SKU, warehouse, stock) | Group by key fields, count > 1 |
| `doubled_stock` | Stock value exactly 2x previous value | Compare to history |
| `negative_stock` | Impossible negative stock values | Filter stock < 0 |
| `spike` | Unusually high stock (5000+ units) | Z-score > threshold |
| `stale_timestamp` | Data older than expected | Compare timestamps |

## File Structure

```
supply_watchdog/
├── lib/
│   ├── supply_watchdog.ex      # Main API
│   ├── agent.ex                # Agent builders for each tier
│   ├── tools.ex                # Tool implementations
│   └── generators/
│       └── inventory.ex        # Test data generator
├── data/                       # Generated at runtime
│   ├── inventory.csv           # Current inventory
│   ├── inventory_history.csv   # Historical values
│   └── ground_truth.json       # Expected anomalies
├── flags/                      # Tier outputs
│   ├── tier1.json              # Pattern matches
│   └── tier2.json              # Scored anomalies
├── fixes/                      # Proposed corrections
│   └── proposed.json           # Fixes with reasoning
├── traces/                     # Execution traces
├── run.exs                     # CLI runner
└── mix.exs
```

## Example: Detecting Duplicates

**Human input:**
```
"Find duplicate inventory entries - same SKU and warehouse with identical stock values"
```

**Tier 1 might generate:**
```lisp
(let [data (read_csv "data/inventory.csv")
      grouped (group_by data ["sku" "warehouse" "stock"])
      duplicates (filter grouped (fn [g] (> (get g "count") 1)))]
  (write_json "flags/tier1.json" (flat-map duplicates (fn [g] (get g "records"))))
  (return {:flagged (count duplicates) :output_path "flags/tier1.json"}))
```

**Tier 2 adds statistical context:**
- Z-scores for stock values
- Severity ranking
- Duplicate group identification

**Tier 3 proposes fixes:**
```json
{
  "sku": "HRG-4521",
  "warehouse": "WH-EU",
  "field": "stock",
  "old_value": 2400,
  "new_value": 1200,
  "reason": "Duplicate sync detected - same payload sent twice at 08:15:00Z and 08:15:01Z",
  "confidence": 0.92
}
```

## Extending the Example

### Add New Anomaly Types

1. Add generator in `lib/generators/inventory.ex`:
```elixir
defp inject_anomaly_type(records, anomalies, :my_anomaly, count, base_date) do
  # Generate anomalous records
end
```

2. The agent will learn to detect it from task descriptions.

### Add New Tools

1. Add tool in `lib/tools.ex`:
```elixir
defp my_new_tool do
  Tool.new(
    name: "my_tool",
    description: "What it does",
    parameters: %{...},
    handler: fn args -> ... end
  )
end
```

2. Include in appropriate tier's tool set.

### Custom Tiers

Create specialized agents for domain-specific analysis:
```elixir
def my_custom_tier(base_path, opts \\ []) do
  SubAgent.new(
    prompt: my_custom_prompt(),
    signature: "(input :string) -> {result :map}",
    tools: my_custom_tools(base_path),
    ...
  )
end
```

## Comparison with Other Examples

| Feature | `supply_watchdog/` | `rlm_recursive/` |
|---------|-------------------|------------------|
| Pattern | Tiered pipeline | Recursive subdivision |
| Communication | Filesystem (JSON) | In-memory + :self tool |
| Use case | Data quality monitoring | Large corpus processing |
| Human input | Task description | Query |

## LLM Provider Setup

See [llm_client/README.md](../../llm_client/README.md) for provider configuration.

## References

- [GO 2026 AI Focus](../../private/go-2026-agentic-use-cases.md) - Original use case analysis
- [SubAgent Guide](../../docs/guides/subagent-getting-started.md) - SubAgent API documentation
