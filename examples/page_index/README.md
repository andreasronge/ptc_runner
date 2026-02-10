# PageIndex - Hierarchical Document Retrieval

Vectorless, reasoning-based RAG using hierarchical tree indexing. Inspired by [VectifyAI/PageIndex](https://github.com/VectifyAI/PageIndex).

Instead of chunk-embed-search, PageIndex parses a document's Table of Contents into a tree with LLM-generated summaries, then navigates the tree through reasoning to find relevant sections.

## How It Works

**Indexing** — Parse the PDF's TOC with an LLM, generate summaries for each section in parallel (`Task.async_stream`), and build a tree:

```
Document PDF → TocParser (LLM) → Section tree → Parallel summarization → Index JSON
```

**Retrieval** — Uses `PlanExecutor` with a search `SubAgentTool`:

1. The MetaPlanner LLM generates a structured plan (agents, tasks, dependencies, signatures)
2. `PlanExecutor` runs tasks in dependency order, parallelizing independent fetches
3. Each search task spawns a child `SubAgent` that navigates sections, fetches content, and returns structured findings
4. A synthesis task combines findings into a cited answer

## Setup

```bash
cd examples/page_index
mix deps.get
```

Download a sample PDF (e.g., [3M 2022 10-K](https://www.sec.gov/Archives/edgar/data/66740/000006674023000012/mmm-20221231.htm)) and save it to `data/3M_2022_10K.pdf`.

## Usage

```bash
# Index a document (parses TOC, generates summaries)
mix run run.exs --index data/3M_2022_10K.pdf

# Query the index
mix run run.exs --query "What was 3M's total revenue in 2022?" --pdf data/3M_2022_10K.pdf

# Query with tracing enabled
mix run run.exs --query "Is 3M a capital intensive business?" --pdf data/3M_2022_10K.pdf --trace

# Show an existing index
mix run run.exs --show data/3M_2022_10K_index.json
```

Options: `--model <name>` (default: `bedrock:haiku`), `--trace` (writes to `traces/`).

Short aliases: `-m`, `-q`, `-t`.

## Example: MetaPlanner Generated Plan

`PlanExecutor.run/2` sends a **mission** (the question + available document sections with summaries) and **constraints** (the required JSON structure) to the LLM. The LLM generates the entire plan — agent definitions, prompts, task decomposition, signatures, dependencies, and verification expressions — from scratch each time.

The agent prompts (e.g., "You are a quantitative analyst...") are **invented by the planner LLM**, not hardcoded. Different questions produce different agent configurations.

Below is a real plan generated for: *"Is 3M a capital-intensive business based on FY2022 data?"*

The four `fetch_*` tasks have no dependencies and run in parallel. The `calculator` waits for all fetches, then computes ratios. The `synthesizer` produces the final answer.

```json
{
  "agents": {
    "calculator": {
      "prompt": "You are a quantitative analyst. Extract numeric values into let bindings and use arithmetic expressions (/, *, +, -) to compute ratios.",
      "tools": []
    },
    "document_analyst": {
      "prompt": "You are a data extraction agent. Use grep_section first to locate keywords, then fetch_section at the returned offset.",
      "tools": ["fetch_section", "grep_section"]
    },
    "synthesizer": {
      "prompt": "You produce clear, evidence-based answers from structured data.",
      "tools": []
    }
  },
  "tasks": [
    {"id": "fetch_balance_sheet", "agent": "document_analyst", "depends_on": [],
     "input": "Extract: total PP&E (net) and total assets for FY2022.",
     "signature": "{ppe_net_2022 :float, total_assets_2022 :float, page :int}"},
    {"id": "fetch_cash_flow", "agent": "document_analyst", "depends_on": [],
     "input": "Extract: capital expenditures for FY2022.",
     "signature": "{capex_2022 :float, page :int}"},
    {"id": "fetch_income_statement", "agent": "document_analyst", "depends_on": [],
     "input": "Extract: total net sales for FY2022.",
     "signature": "{revenue_2022 :float, page :int}"},
    {"id": "fetch_depreciation", "agent": "document_analyst", "depends_on": [],
     "input": "Extract: depreciation expense for FY2022.",
     "signature": "{depreciation_2022 :float, page :int}"},
    {"id": "compute_metrics", "agent": "calculator",
     "depends_on": ["fetch_balance_sheet", "fetch_cash_flow", "fetch_income_statement", "fetch_depreciation"],
     "input": "Calculate: capex/revenue %, PP&E/assets %, depreciation/revenue %",
     "output": "ptc_lisp",
     "signature": "{capex_to_revenue_pct :float, ppe_to_assets_pct :float}"},
    {"id": "final_answer", "type": "synthesis_gate", "agent": "synthesizer",
     "depends_on": ["compute_metrics"],
     "input": "Determine whether 3M is capital-intensive. Provide a yes/no with evidence.",
     "signature": "{is_capital_intensive :bool, rationale :string}"}
  ]
}
```

Key plan features:
- **Parallel fetches**: the four `fetch_*` tasks have `depends_on: []` and execute concurrently
- **Typed signatures**: each task declares its output shape so downstream tasks know what to expect
- **`output: "ptc_lisp"`**: tells the calculator agent to write a PTC-Lisp program rather than free-text
- **`synthesis_gate`**: marks `final_answer` as the terminal task

## Example: PTC-Lisp Programs

**Computation task** — Planner mode generates ratio calculations from fetched data:

```clojure
(let [capex_2022 1749.0
      revenue_2022 34229.0
      ppe_net_2022 9178.0
      total_assets_2022 46455.0
      capex_to_revenue_pct (* 100.0 (/ capex_2022 revenue_2022))
      ppe_to_assets_pct (* 100.0 (/ ppe_net_2022 total_assets_2022))]
  (return {:capex_to_revenue_pct capex_to_revenue_pct
           :ppe_to_assets_pct ppe_to_assets_pct}))
```

**Cross-task data access** — Planner agents read results from earlier tasks via `data/results`:

```clojure
(let [segments (get-in data/results ["fetch_segment_data" "segments"])
      overall  (get-in data/results ["fetch_overall_growth" "overall_pct"])]
  (return {:overall_pct overall
           :segments (map (fn [seg]
                            {:name (get seg "name")
                             :delta (- (get seg "pct") overall)})
                          segments)}))
```

## Architecture

```
lib/page_index/
├── parser.ex                  # PDF text extraction (via pdfplumber)
├── toc_parser.ex              # LLM-based TOC parsing
├── fine_indexer.ex             # Index builder (TOC → summaries → tree)
├── plan_retriever.ex             # PlanExecutor + search SubAgentTool retrieval
├── retriever_toolkit.ex       # Shared helpers (fuzzy fetch, tree ops, search tool)
└── page_index.ex              # Public API
```

## References

- [VectifyAI/PageIndex](https://github.com/VectifyAI/PageIndex) — Original Python implementation
