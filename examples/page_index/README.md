# PageIndex - Hierarchical Document Retrieval

Vectorless, reasoning-based RAG using hierarchical tree indexing. Inspired by [VectifyAI/PageIndex](https://github.com/VectifyAI/PageIndex).

Instead of chunk-embed-search, PageIndex parses a document's Table of Contents into a tree with LLM-generated summaries, then navigates the tree through reasoning to find relevant sections.

## How It Works

**Indexing** — Parse the PDF's TOC with an LLM, generate summaries for each section in parallel (`Task.async_stream`), and build a tree:

```
Document PDF → TocParser (LLM) → Section tree → Parallel summarization → Index JSON
```

**Retrieval** — Multiple strategies tailored to query complexity:

| Mode | How it works | Best for |
|------|-------------|----------|
| `--simple` | Score all nodes, fetch top-k, then synthesize | Predictable, single-hop lookups |
| (default) | Single SubAgent with `get-content` tool | Most standard questions |
| `--iterative` | Multi-round "Seeker-Extractor" loop | Fuzzy, scattered, or deep information |
| `--planner` | MetaPlanner decomposes into parallel fetch/compute tasks | Multi-hop reasoning and PCE |
| `--hybrid` | Classified query → routes to best strategy | Production default; balances cost/latency |

### Plan-Code-Execute (PCE)

When using `--planner` (or routed via `--hybrid` for math-heavy queries), PageIndex implements the **Plan-Code-Execute** pattern. Instead of asking an LLM to perform arithmetic in its head, the planner generates deterministic code to operate on structured findings retrieved by sub-agents.

This eliminates calculation hallucinations and "lossy synthesis" by shifting logic from natural language to a deterministic execution environment.

Learn more about this pattern here: [Plan-Code-Execute: Designing Agents That Create Their Own Tools](https://towardsdatascience.com/plan-code-execute-designing-agents-that-create-their-own-tools/).

## Setup

```bash
cd examples/page_index
mix deps.get
mix download              # Download sample PDFs (~8 MB)
```

## Usage

```bash
# Index a document (parses TOC, generates summaries)
mix run run.exs --index data/3M_2022_10K.pdf

# Query with default agent mode
mix run run.exs --query "What are 3M's business segments?" --pdf data/3M_2022_10K.pdf

# Query with MetaPlanner (for complex multi-hop questions)
mix run run.exs --query "Is 3M a capital intensive business?" --pdf data/3M_2022_10K.pdf --planner --trace

# Show an existing index
mix run run.exs --show data/3M_2022_10K_index.json
```

Options: `--model <name>` (default: `bedrock:haiku`), `--trace` (writes to `traces/`), `--simple`, `--iterative`, `--planner`, `--hybrid`.

## Example: Planner Execution

For the query *"Is 3M a capital intensive business based on FY2022 data?"* with `--planner`, MetaPlanner generates:

```
Agents:
  fetcher     (tools: fetch_section)  — retrieves document sections
  analyst     (no tools)              — computes derived metrics via PTC-Lisp
  synthesizer (no tools)              — produces final verdict

Tasks:
  fetch_balance_sheet      → fetcher                                         parallel ┐
  fetch_cash_flow          → fetcher                                         parallel ┤
  fetch_business_overview  → fetcher                                         parallel ┤
  fetch_ppe_note           → fetcher                                         parallel ┘
  compute_capital_intensity → analyst    depends_on: [balance_sheet, cash_flow, ppe_note]
  final_answer             → synthesizer depends_on: [compute, business_overview]  (synthesis_gate)
```

Execution: 4 fetches run in parallel (~3s), then the analyst computes PP&E/assets, CapEx/revenue, and CapEx/OCF ratios, then the synthesizer produces the final answer with rationale. Total: ~53s, 0 replans.

Use `--trace` and open `priv/trace_viewer.html` to visualize the full execution timeline.

## Architecture
 
 ```
 lib/page_index/
├── parser.ex              # PDF text extraction (via pdfplumber)
├── toc_parser.ex          # LLM-based TOC parsing
├── fine_indexer.ex        # Index builder (TOC → summaries → tree)
├── document_tools.ex      # Shared search, fetch, and formatting tools
├── retriever.ex           # Agent-based and simple retrieval
├── iterative_retriever.ex # Multi-round seeker-extractor loop
├── planner_retriever.ex   # MetaPlanner-based multi-hop retrieval
└── hybrid_retriever.ex    # Complexity classifier and strategy router
 ```

## Known Limitation: Planner Interpretation Instability

The planner mode reliably extracts consistent numbers (e.g., PPE=9178, CapEx=1749, revenue=34229) but the synthesis step is unstable for subjective questions like "Is 3M capital-intensive?" — different runs pick different metrics and thresholds (CapEx/Revenue ~5% vs PPE/Assets ~20%), leading to contradictory conclusions from identical data. Root cause: the planner prompt has no canonical definition of analytical concepts, so each generated plan embeds different interpretation criteria.

## Alternative Approaches to Consider

**Vector RAG baseline** — Chunk, embed, cosine-search. Simpler, faster, but loses document structure and can't reason about which sections to explore. Good baseline to compare against.

**Explicit tree navigation tools** — Instead of giving the agent all summaries upfront, provide `get-children`, `get-summary`, `get-content` tools and let it walk the tree step by step. More control over token usage for very large documents, but requires more tool calls.

**Hybrid** — Use vector search to pre-filter candidate sections, then tree navigation to verify and gather context. Combines speed of embeddings with interpretability of reasoning.

## References

- [VectifyAI/PageIndex](https://github.com/VectifyAI/PageIndex) — Original Python implementation
- [FinanceBench](https://github.com/patronus-ai/financebench) — Source of test questions (`data/questions.json`, MIT license)
