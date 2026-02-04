defmodule SupplyWatchdog.Agent do
  @moduledoc """
  Agent builders for the three-tier Supply Watchdog system.

  ## Architecture

  The watchdog uses a tiered approach where each tier processes
  progressively filtered data:

  1. **Tier 1 (Pattern Detector)** - Uses rules/patterns to flag potential issues
  2. **Tier 2 (Statistical Analyzer)** - Applies statistical methods to score/rank
  3. **Tier 3 (Root Cause Reasoner)** - Determines cause and proposes fixes

  Each tier's output becomes the next tier's input via filesystem.

  ## Example

      # Human describes what to look for
      task = "Find duplicate inventory entries - same SKU and warehouse with identical stock values"

      # Tier 1 generates and runs detection program
      agent = SupplyWatchdog.Agent.tier1(base_path)
      {:ok, step} = SubAgent.run(agent, context: %{"task" => task}, llm: llm)

  """

  alias PtcRunner.SubAgent
  alias SupplyWatchdog.Tools

  @doc """
  Create a Tier 1 agent for pattern-based anomaly detection.

  The agent receives a natural language description of what anomalies
  to look for and generates code to detect them.

  ## Input Context

    * `task` - Natural language description of anomalies to find
    * `schema` - Optional schema description of the data

  ## Output

  Writes flagged records to `flags/tier1.json`
  """
  def tier1(base_path, opts \\ []) do
    max_turns = Keyword.get(opts, :max_turns, 10)
    llm = Keyword.get(opts, :llm)

    SubAgent.new(
      prompt: tier1_prompt(),
      signature: "(task :string) -> {flagged :int, output_path :string}",
      description: "Detect anomalies based on pattern description",
      tools: Tools.tier1_tools(base_path),
      max_turns: max_turns,
      llm: llm
    )
  end

  @doc """
  Create a Tier 2 agent for statistical analysis of flagged records.

  Takes the output from Tier 1 and applies statistical methods
  to score and rank the anomalies.

  ## Input Context

    * `input_path` - Path to Tier 1 output (flags/tier1.json)

  ## Output

  Writes scored anomalies to `flags/tier2.json`
  """
  def tier2(base_path, opts \\ []) do
    max_turns = Keyword.get(opts, :max_turns, 10)
    llm = Keyword.get(opts, :llm)

    SubAgent.new(
      prompt: tier2_prompt(),
      signature: "(input_path :string) -> {analyzed :int, output_path :string}",
      description: "Statistically analyze and score flagged anomalies",
      tools: Tools.tier2_tools(base_path),
      max_turns: max_turns,
      llm: llm
    )
  end

  @doc """
  Create a Tier 3 agent for root cause analysis and fix proposals.

  Takes the scored anomalies from Tier 2 and determines
  root causes, proposing corrections where possible.

  ## Input Context

    * `input_path` - Path to Tier 2 output (flags/tier2.json)

  ## Output

  Writes proposed fixes to `fixes/proposed.json`
  """
  def tier3(base_path, opts \\ []) do
    max_turns = Keyword.get(opts, :max_turns, 15)
    llm = Keyword.get(opts, :llm)

    SubAgent.new(
      prompt: tier3_prompt(),
      signature: "(input_path :string) -> {fixes_proposed :int, output_path :string}",
      description: "Analyze root causes and propose corrections",
      tools: Tools.tier3_tools(base_path),
      max_turns: max_turns,
      llm: llm
    )
  end

  @doc """
  Create a single-tier detector agent for simpler use cases.

  This agent combines pattern detection with basic analysis,
  useful for testing specific anomaly types.

  ## Input Context

    * `task` - What to detect (e.g., "find negative stock values")
    * `data_path` - Path to data file

  """
  def detector(base_path, opts \\ []) do
    max_turns = Keyword.get(opts, :max_turns, 10)
    llm = Keyword.get(opts, :llm)

    all_tools =
      Map.merge(
        Tools.tier1_tools(base_path),
        Tools.tier2_tools(base_path)
      )

    SubAgent.new(
      prompt: detector_prompt(),
      signature: "(task :string, data_path :string) -> {anomalies [:map], count :int}",
      description: "Detect and analyze anomalies in a single pass",
      tools: all_tools,
      max_turns: max_turns,
      llm: llm
    )
  end

  # ============================================
  # Prompts
  # ============================================

  defp tier1_prompt do
    """
    You are a data quality watchdog for inventory data.

    ## Input
    - data/task: Natural language description of what anomalies to find

    ## Available Data
    - `data/inventory.csv`: Inventory records (read it first to see the schema)

    ## Process
    1. Read the inventory data using `read_csv` to understand its structure
    2. Interpret the task using data quality principles (see below)
    3. Use appropriate tools to detect the anomalies
    4. Write ONLY the anomalous records to `flags/tier1.json`

    ## Data Quality Principles

    **Duplicates**: In data quality, "duplicate" means the SAME record entered twice.
    - A duplicate is NOT "same SKU appears in different warehouses" (that's normal distribution)
    - A duplicate is NOT "same SKU appears with different quantities" (that's inventory change)
    - A duplicate IS when the SAME combination of identifying fields appears twice
    - For inventory: duplicate = same (SKU + warehouse + stock) appearing more than once
    - Use `group_by` on ALL key fields together, then find groups with count > 1
    - Only flag records where the grouping key (all fields combined) repeats

    **Impossible values**: Values that violate business rules
    - Quantities cannot be negative
    - Dates cannot be in the future
    - Required fields cannot be empty

    **Statistical outliers**: Values far from normal distribution
    - Use z_score to identify values >3 standard deviations from mean
    - Consider domain context (a "high" value depends on what's normal)

    ## Output
    Return `{:flagged N :output_path "flags/tier1.json"}` where N is the count of flagged records.

    IMPORTANT: Only flag records that actually match the anomaly described in the task.
    Precision matters - false positives waste analyst time.
    """
  end

  defp tier2_prompt do
    """
    You are a statistical analyzer for inventory anomalies.

    ## Input
    - data/input_path: Path to flagged records from Tier 1 (JSON file)

    ## Process
    1. Read the flagged records using `read_json`
    2. Apply statistical analysis to numeric fields:
       - Use `z_score` to calculate how far values deviate from the mean
       - Use `rank_by` to order by severity
    3. Add a "severity" field to each record based on the analysis
    4. Write enriched results to `flags/tier2.json`

    ## Severity Classification
    Assign severity based on data quality impact:
    - "critical": Impossible values (negative quantities, null required fields)
    - "high": Exact duplicates, values >3 standard deviations from mean
    - "medium": Logical duplicates, values 2-3 standard deviations from mean
    - "low": Minor anomalies, values 1-2 standard deviations from mean

    ## Output
    Return `{:analyzed N :output_path "flags/tier2.json"}` where N is the count of analyzed records.

    The output should preserve all original fields and add: z_score, severity, rank.
    """
  end

  defp tier3_prompt do
    """
    You are a root cause analyst for inventory anomalies.

    ## Input
    - data/input_path: Path to scored anomalies from Tier 2 (JSON file)

    ## Process
    1. Read the scored anomalies using `read_json`
    2. For the top anomalies (by severity), investigate:
       - Use `get_history` to see historical values for the SKU
       - Use `get_related` to check for related shipments/orders
    3. For each anomaly you can diagnose, call `propose_fix` with ALL required fields
    4. Write a summary to `fixes/proposed.json`

    ## Using propose_fix

    The `propose_fix` tool requires these parameters - extract them from the anomaly record:
    - sku: The SKU identifier from the anomaly record
    - warehouse: The warehouse from the anomaly record
    - field: Which field is wrong (e.g., "stock")
    - old_value: The current incorrect value
    - new_value: What it should be (based on your analysis)
    - reason: Explain WHY this is wrong and how you determined the fix
    - confidence: 0.0-1.0 based on how certain you are

    Example: If you find a duplicate where stock=500 appears twice, and history shows
    it was 500 before a sync event, propose removing the duplicate by setting one
    record's stock to the correct value.

    ## Root Cause Categories
    - Integration error: duplicate sync, failed update, data sent twice
    - Data entry error: typo, wrong unit, copy-paste mistake
    - System bug: calculation error, rounding issue
    - Legitimate anomaly: actual unusual business activity (do NOT propose fix)

    ## Output
    Return `{:fixes_proposed N :output_path "fixes/proposed.json"}` where N is fixes proposed.

    Only propose fixes when you have evidence. If uncertain, set confidence < 0.7.
    """
  end

  defp detector_prompt do
    """
    You are an inventory anomaly detector.

    ## Input
    - data/task: What anomalies to find
    - data/data_path: Path to data file

    ## Process
    1. Read the data file using `read_csv` to see its structure
    2. Interpret the task using data quality principles:
       - "duplicates" = records with identical key fields that shouldn't coexist
       - "negative" = values below zero where that's impossible
       - "outliers" or "spikes" = statistical anomalies (use z_score)
    3. Apply the appropriate detection method
    4. Return ONLY records that match the anomaly type

    ## Output
    Return `{:anomalies [...] :count N}` with detected anomalies.

    Each anomaly record should include:
    - All original fields from the data
    - anomaly_type: category of the anomaly
    - severity: "critical" (impossible values), "high" (duplicates, >3σ),
                "medium" (2-3σ), "low" (1-2σ)
    - reason: brief explanation of why this is anomalous

    IMPORTANT: Precision matters. Only return records that clearly match the
    requested anomaly type. A record appearing multiple times for the same
    SKU in different warehouses is NOT a duplicate - it's normal inventory
    distribution.
    """
  end
end
