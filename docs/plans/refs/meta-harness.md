# Meta-Harness: End-to-End Optimization of Model Harnesses

**Yoonho Lee** — Stanford  
**Roshen Nair** — Stanford  
**Qizheng Zhang** — Stanford  
**Kangwook Lee** — KRAFTON  
**Omar Khattab** — MIT  
**Chelsea Finn** — Stanford

- Project page w/ interactive demo: https://yoonholee.com/meta-harness/
- Optimized harness: https://github.com/stanford-iris-lab/meta-harness-tbench2-artifact

---

## Abstract

The performance of large language model (LLM) systems depends not only on model weights, but also on their *harness*: the code that determines what information to store, retrieve, and present to the model. Yet harnesses are still designed largely by hand, and existing text optimizers are poorly matched to this setting because they compress feedback too aggressively: they are memoryless, condition only on scalar scores, or restrict feedback to short templates or summaries. We introduce **Meta-Harness**, an outer-loop system that searches over harness code for LLM applications. It uses an agentic proposer that accesses the source code, scores, and execution traces of all prior candidates through a filesystem. On online text classification, Meta-Harness improves over a state-of-the-art context management system by 7.7 points while using 4× fewer context tokens. On retrieval-augmented math reasoning, a single discovered harness improves accuracy on 200 IMO-level problems by 4.7 points on average across five held-out models. On agentic coding, discovered harnesses surpass the best hand-engineered baselines on TerminalBench-2. Together, these results show that richer access to prior experience can enable automated harness engineering.

---

## 1 Introduction

Changing the harness around a fixed large language model (LLM) can produce a 6× performance gap on the same benchmark [47]. The *harness*—the code that determines what to store, retrieve, and show to the model—often matters as much as the model itself. This sensitivity has led to growing interest in **harness engineering**, the practice of refining the code around an LLM to improve the overall system's performance [36; 21; 10; 9]. But despite its importance, harness engineering remains largely manual: practitioners inspect failures, adjust heuristics, and iterate on a small number of designs. In this paper, we ask whether this process itself can be automated.

A natural starting point is recent work on text optimization, since harness engineering also involves iteratively improving text and code artifacts using feedback from prior attempts [38; 39; 35; 26; 1]. However, these methods are poorly matched to harness engineering because they typically operate with short-horizon or heavily compressed feedback: some condition only on the current candidate [31; 51; 53], others rely primarily on scalar scores [35; 12], and others restrict feedback to short templates or LLM-generated summaries [1; 26]. This is a pragmatic scalability choice, not evidence that longer-range dependencies are uninformative. Harnesses act over long horizons: a single choice about what to store, when to retrieve it, or how to present it can affect behavior many reasoning steps later. Compressed feedback often removes the information needed to trace downstream failures to earlier harness decisions. Across the tasks studied by several representative text optimizers, the available context per optimization step ranges from only 100 to 30,000 tokens (Table 1), far below the diagnostic footprint of harness search. More broadly, work on retrieval and memory-augmented language models suggests that useful context should often be accessed adaptively rather than monolithically packed into a single prompt [28; 48; 37; 56].

We address this limitation with **Meta-Harness**, an agentic harness for optimizing harnesses via end-to-end search (Figure 2). Its proposer is a coding agent, i.e., a language-model-based system that can invoke developer tools and modify code. The choice of coding agent (rather than raw LLM) matters because the amount of experience quickly exceeds context limits, so the proposer must decide what to inspect and validate edits through direct interaction with the codebase. Its key design choice is to expose full history through a **filesystem**, enabling selective diagnosis of raw prior code and execution traces rather than optimization from compressed per-candidate summaries. For every previous candidate harness, the filesystem stores the source code, evaluation scores, and execution traces, which the proposer retrieves via standard operations such as `grep` and `cat` rather than ingesting them as a single prompt. In practice, the proposer reads a median of 82 files per iteration in our most demanding setting, referencing over 20 prior candidates per step (Appendix A). In the settings we study, a single evaluation can produce up to 10,000,000 tokens of diagnostic information, roughly three orders of magnitude beyond the largest feedback budgets used in prior text optimization settings (Table 1).

We evaluate Meta-Harness on online text classification, mathematical reasoning, and agentic coding. On online text classification, harnesses discovered by Meta-Harness improve over Agentic Context Engineering (ACE, Zhang et al. [59]) by 7.7 points while using 4× fewer context tokens, and match the next-best text optimizer's final performance after 60 proposals with only four (Figure 1). On retrieval-augmented math reasoning, a single discovered harness improves accuracy on 200 IMO-level problems by 4.7 points on average across five held-out models. On TerminalBench-2, the discovered harness surpasses Terminus-KIRA and ranks #1 among all Haiku 4.5 agents.

**Table 1: Comparison of text optimization methods and their settings.**

| Method | History | Log content | MTok/iter |
|--------|---------|-------------|-----------|
| OPRO [51] | Window | past (solution, score) pairs | 0.002 |
| TextGrad [53] | Last | textual feedback on current artifact | 0.015 |
| AlphaEvolve [35] | Window | program database + eval. scores | 0.022 |
| GEPA [1] | Summary | reflective feedback from rollout traces | 0.008 |
| Feedback Descent [26] | Summary | comparison + textual feedback | 0.012 |
| TTT-Discover [54] | Window | prev. solution fragment | 0.026 |
| **Meta-Harness** | **Full** | ***all* logs and scores** | **10.0** |

Each row represents a method collapsed across tasks. MTok/iter is our best estimate of the full context generated from one evaluation of a text artifact in the largest setting considered in each paper. This paper considers settings that yield orders-of-magnitude more context per artifact evaluation.

---

## 2 Related Work

At a high level, Meta-Harness brings ideas from the broader literature on credit assignment and meta-learning [40; 46; 3; 17; 44; 2] in a new regime enabled by recent advances in coding agents. Rather than updating model weights, the system assigns credit at the harness level: it uses experience from past rollouts to deliberately reason about which steps and components are responsible for failures, then rewrites the external code that governs future behavior. More specifically, the method lies at the intersection of several recent research threads; it is most directly related to work on adaptive access to external context, executable code search, and text optimization.

**External memory and adaptive access.** Several prior works note the benefits of treating large knowledge sources or long inputs as external resources that a language model accesses adaptively, rather than consuming them in a single pass. Specifically, retrieval-augmented generation [28], interleaved retrieval and reasoning [48], memory-based agents [37], or recursive language models [56] are mechanisms for adaptive access to external context. Meta-Harness uses a similar access pattern, but in the more demanding setting of harness engineering, where the proposer selectively inspects a large external history of code, scores, and execution traces to improve context-management procedures themselves.

**Executable code search.** Recent methods search over executable code for functions, workflows, or agent designs. Early work proposes using large models as mutation and crossover operators in evolutionary program search [27]. Later methods evolve designated functions within fixed program scaffolds [39], use meta-agents to program new agents from prior discoveries [20], or search over workflow graphs for agentic systems [58]. Another line of work searches over memory designs for continual-learning agents, where memory persists across task streams [57; 50]. In contrast, Meta-Harness searches over domain-specific harnesses, including prompt construction, retrieval, and state update strategies that reset between tasks. Its outer loop is deliberately minimal: instead of relying on a fixed scaffold, an archive of prior discoveries, or a persistent memory mechanism, it gives the proposer unrestricted filesystem access to prior experience. This lets the agent decide what information to inspect and enables search over full harness implementations rather than a predefined space of context-management procedures.

**Text optimization methods.** Meta-Harness is also closely related to methods such as ProTeGi, TextGrad, OPRO, GEPA, AlphaEvolve/OpenEvolve, and Feedback Descent, which iteratively improve prompts or other text artifacts using feedback from prior attempts [38; 31; 53; 51; 1; 35; 43; 26]. However, these methods are less well suited to harness engineering, where optimization targets a complete executable procedure, and the relevant environmental feedback is distributed across code, scores, and execution traces in a way that is hard to summarize up front. Rather than reacting only to aggregate scores or summaries, the proposer in Meta-Harness can reason over failed examples and their execution traces to propose targeted edits. See Table 1 for a comparison of problem scale considered in those papers and ours, and Figures 1 and 4 for a direct comparison with OpenEvolve, GEPA, and TTT-Discover in our problem setting.

---

## 3 Meta-Harness: A Harness for Optimizing Harnesses

This section describes Meta-Harness, our outer-loop procedure for searching over task-specific harnesses. Meta-Harness is built on the idea that harness optimization benefits from allowing a proposer to selectively inspect prior code and execution traces via filesystem access, rather than optimizing from lossy summaries or an additional hand-designed search structure. At a high level, it repeatedly proposes, evaluates, and logs new harnesses.

Meta-Harness is itself a harness in the broad sense (hence the name), since it determines what information the proposer model sees during search. Unless otherwise noted, we use *harness* to refer to the task-specific programs being optimized.

**Objective.** A harness is a stateful program that wraps a language model and determines what context the model sees at each step. The goal is simple: find the harness that makes the underlying model perform best on the target task distribution. Formally, let M denote a fixed language model and X a task distribution. For a harness H and task instance x ∼ X, we execute a rollout trajectory τ ∼ p_M(H, x). The harness constructs prompts for M, the model responds, and the harness updates its state after each interaction. A task-specific reward function r(τ, x) scores the trajectory. The objective of harness optimization is to find the harness that maximizes the expected final reward:

```
H* = arg max_H E_{x∼X, τ∼p_M(H,x)} r(τ, x)
```

When multiple objectives are relevant (e.g., accuracy and context cost), we evaluate candidates under Pareto dominance and report the resulting frontier. In practice, this search has traditionally been carried out by human engineers and researchers, who iteratively refine prompts, context-management rules, and tool-use logic by hand.

**Meta-Harness search loop.** Meta-Harness uses a single coding-agent proposer with access to a growing filesystem D that serves as its feedback channel. Here, a coding agent is a language-model-based system that can invoke developer tools and modify code. Unlike prior systems that externalize the improvement logic in a hand-designed search loop, Meta-Harness delegates diagnosis and proposal to the coding agent itself: it decides which prior artifacts to inspect, which failure modes to address, and whether to make a local edit or a more substantial rewrite. Equivalently, the proposer is not a raw next-token model operating on a fixed prompt assembled by the outer loop; it is an agent that retrieves information, navigates prior artifacts, and edits code as part of the search itself. Each evaluated harness contributes a directory containing its source code, scores, and execution traces (such as prompts, tool calls, model outputs, and state updates). The filesystem is typically far larger than the proposer's context window, so the proposer queries it through terminal tools such as `grep` and `cat` rather than ingesting it as a single prompt. At each iteration, the proposer first inspects prior code, scores, and execution traces, then reasons about likely failure modes before generating a new harness.

Meta-Harness maintains a population H and a Pareto frontier over evaluated harnesses, but imposes no parent-selection rule: the proposer is free to inspect any prior harness and its execution trace when proposing new ones. We run evolution for a fixed number of iterations and perform a final test-set evaluation on the Pareto frontier. This simplicity is deliberate: by leaving diagnosis and edit decisions to the proposer rather than hard-coding search heuristics, Meta-Harness can improve automatically as coding agents become more capable. The proposer never sees test-set results; its only feedback comes from the search set, the subset of task instances used to evaluate candidate harnesses during search and generate the feedback signal for improvement, and from execution traces logged during those search runs.

**Advantages of code-space search.** Harness optimization occurs in code space, where small changes to retrieval, memory, or prompt-construction logic can affect behavior many steps later, making local search heuristics poorly matched to the problem. By inspecting execution traces, the proposer can often infer *why* a harness failed and which earlier design choices likely contributed to the failure, not just *that* it failed, as illustrated by the search trajectories in Appendices A and A.2. There, we see that the proposer reads broadly across prior code and logs, then uses those traces to identify confounded edits, isolate likely causal changes, and shift toward safer modifications after repeated regressions. The proposer can therefore modify the harness at the level of algorithmic structure, ranging from changes to retrieval, memory, or prompt-construction logic to full program rewrites, rather than filling in templates or applying predefined mutation operators. In practice, it often starts from a strong prior harness, but this is an emergent strategy rather than a hard-coded rule. Although the search space is large, representing harnesses as programs provides a natural regularization bias: coding models tend to propose coherent algorithms rather than brittle, hard-coded solutions, which biases the search toward reusable context-management procedures. This action space is closely aligned with the read–write–execute workflows on which frontier coding assistants are trained.

**Practical implementation.** In our experiments, each harness is a single-file Python program that modifies task-specific prompting, retrieval, memory, and orchestration logic. In our experiments, the proposer P is Claude Code [4] with Opus-4.6. The proposer is guided by a minimal domain-specific skill that describes where to write new harnesses, how to inspect previous harnesses and their execution traces, and what files it can and cannot modify. The base model M varies by domain and is always frozen; see Section 4 for details. In our experiments, a typical run evaluates roughly 60 harnesses over 20 iterations. We provide additional tips for implementing Meta-Harness in a new domain in Appendix D.

**Algorithm 1: Meta-Harness outer loop over harnesses**

```
Input: tasks X, LLM M, proposer P, iterations N
Initialize: population H        ▷ Initial set of valid harnesses
Initialize: filesystem D ← ∅   ▷ stores code, scores, traces
for H ∈ H do
    E_H ← Evaluate(H, M, X)
    D ← D ∪ {(H, E_H)}
for t = 1 ... N do
    Proposer P queries filesystem D    ▷ inspects prior harnesses and scores
    Proposer P proposes k new harnesses {H_1, ..., H_k}
    for H in {H_1, ..., H_k} do
        if H passes interface validation then
            D ← D ∪ {(H, EVALUATE(H, M, X))}
return Pareto frontier of harnesses stored in D
```

---

## 4 Experiments

We evaluate Meta-Harness on three task domains: online text classification, math reasoning, and agentic coding. In each domain, we compare harnesses discovered by our search against domain-appropriate baselines using the standard evaluation metric.

We compare against two main classes of methods. (1) **Human-designed strategies**: hand-crafted harnesses for each domain, representing the current state of the art in context construction. (2) **Program-search methods**: these methods search over candidate harnesses using feedback and reward signals, but are designed for smaller-scale settings than harness engineering.

### 4.1 Online Text Classification

We follow the online text classification setup of Zhang et al. [59]; Ye et al. [52]: an LLM receives labeled examples one at a time, updates its memory, and is evaluated on a held-out test set. We use GPT-OSS-120B as the LLM text classifier, and consider the problem of designing a harness for text classification. We use three datasets, chosen for difficulty and domain diversity: **LawBench** (Law) [16] predicts criminal charges from case descriptions (215 classes); **Symptom2Disease** (S2D) [19] predicts diseases from symptom descriptions (22 classes); and **USPTO-50k** [41] predicts precursor reactants from product molecules (180 classes). We initialize the search population H from the main baseline harnesses in this setting: zero-shot, few-shot, ACE, and MCE. We ran 20 evolution iterations with two candidates per iteration, producing 40 candidate harnesses.

**Table 2: Test-set metrics for all harnesses on the three datasets.**

| Harness | USPTO | S2D | Law | Avg Acc | Ctx ↓ |
|---------|-------|-----|-----|---------|--------|
| Zero-Shot | 12.0 | 63.2 | 7.0 | 27.4 | 0 |
| Few-Shot (8) | 14.0 | 67.9 | 21.0 | 34.3 | 2.0 |
| Few-Shot (32) | 13.0 | 72.2 | 21.0 | 35.4 | 7.9 |
| Few-Shot (all) | 15.0 | 78.3 | 29.0 | 40.8 | 12.3 |
| MCE [52]† | 14.0 | 83.0 | 23.0 | 40.0 | 28.5 |
| ACE [59]† | **16.0** | 77.8 | 29.0 | 40.9 | 50.8 |
| **Meta-Harness** | 14.0 | **86.8** | **45.0** | **48.6** | 11.4 |

Ctx denotes additional input tokens in context (thousands). †: implementation from Ye et al. [52]. ↓: lower is better. Meta-Harness improves online text classification accuracy while using a smaller input context.

**Comparison vs text optimizers.** We compare Meta-Harness against representative methods for optimizing text. For a fair comparison, we use the same proposer configuration (Opus-4.6 with max reasoning), select candidates solely based on search-set performance, and hold out the test sets until the final evaluation. Since evaluation is the main computational bottleneck, we give each method the same budget of proposal harness evaluations. We consider the following points of comparison:

- **Best-of-N**: independent samples from the seed with no search structure; a compute-matched control for whether search matters at all.
- **OpenEvolve** [43]: evolutionary search over programs with LLM mutation.
- **TTT-Discover** [55]: we use only the text-optimization component of their method, i.e., proposal selection via the PUCT reuse rule.

> **Meta-Harness is 10× Faster and Converges to a Better Harness**  
> In this setting, Meta-Harness matches the best prior text optimizers (OpenEvolve, TTT-Discover) with 10× fewer full evaluations, and its final accuracy surpasses theirs by more than 10 points.

To isolate which parts of the proposer interface matter most, we compare three conditions in online text classification: a scores-only condition, a scores-plus-summary condition in which the proposer receives LLM-generated summaries but no raw traces, and the full Meta-Harness interface with access to execution traces (Table 3).

**Table 3: Ablation of the information available to the proposer in online text classification.**

| Method | Scores | Code | Summ. | Traces | Median ↑ | Best Acc ↑ | > ZS |
|--------|--------|------|-------|--------|----------|------------|------|
| Scores Only | ✓ | ✓ | × | × | 34.6 | 41.3 | 26 |
| Scores + Summary | ✓ | ✓ | ✓ | × | 34.9 | 38.7 | 23 |
| **Meta-Harness (full)** | ✓ | ✓ | - | ✓ | **50.0** | **56.7** | **39** |

\> ZS: number of runs whose accuracy exceeded the zero-shot baseline. The full Meta-Harness interface substantially outperforms scores-only and scores-plus-summary ablations. Access to raw execution traces is the key ingredient for enabling harness search.

**Table 4: Text classification accuracies of the harnesses proposed by different text optimizers (search set).**

| Method | Median | Best |
|--------|--------|------|
| GEPA [1] | 32.6 | 40.2 |
| Best-of-N | 34.0 | 44.2 |
| OpenEvolve [43] | 39.1 | 43.3 |
| TTT-Discover [55] | 34.1 | 45.6 |
| **Meta-Harness** | **50.0** | **56.7** |

**Comparison vs state-of-the-art harnesses.** Our primary points of comparison are hand-designed harnesses for this problem setting: Agentic Context Engineering (ACE, Zhang et al. [59]) and Meta Context Engineering (MCE, Ye et al. [52]). Results in Table 2 show that Meta-Harness improves substantially over prior hand-designed harnesses. The selected Meta-Harness reaches 48.6% accuracy, outperforming ACE by 7.7 points and MCE by 8.6 points. These gains do not come from using more context: Meta-Harness uses only 11.4K context tokens, versus 50.8K for ACE and 28.5K for MCE.

**Accuracy–Context Tradeoffs.** Because Meta-Harness performs free-form optimization over harness code, we can express a joint preference for both accuracy and context cost rather than committing to a single scalar objective in advance. Given only the current metrics and the desired trade-off, the proposer is able to discover harnesses across a broad range of the frontier, yielding a smooth accuracy–context Pareto curve in Figure 3.

**Out-of-distribution (OOD) task evaluation.** We evaluate whether the discovered harness generalizes to entirely new datasets unseen during search. We consider nine diverse datasets (described in Appendix C.1). The selected Meta-Harness system achieves the best average accuracy (73.1%), outperforming ACE (70.2%) and all few-shot baselines (Table 5). Meta-Harness shows the highest performance on 6/9 datasets.

**Table 5: OOD text classification dataset evaluation.**

| Harness | SciC | FiNER | Amz5 | FPB | GoEmo | Bank77 | News | SciT | TwHate | Avg Acc | Ctx ↓ |
|---------|------|-------|------|-----|-------|--------|------|------|--------|---------|--------|
| Zero-shot | 32.7 | 56.0 | 52.7 | 90.0 | 42.0 | 80.7 | 84.7 | 89.3 | 75.3 | 67.0 | - |
| Few-shot (8) | 34.0 | 63.0 | 54.0 | 90.0 | 44.0 | 82.7 | 84.7 | 91.3 | 76.7 | 68.9 | 2.2 |
| Few-shot (32) | 38.7 | 62.0 | 53.3 | 90.7 | 43.3 | 86.0 | 85.3 | 90.7 | 76.7 | 69.6 | 5.2 |
| Few-shot (all) | 35.3 | 61.0 | 50.0 | 93.3 | 42.7 | 80.7 | 84.0 | 90.0 | 76.7 | 68.2 | 7.4 |
| ACE [59] | 40.7 | 74.0 | 48.0 | 96.7 | 44.0 | 83.3 | 86.0 | 90.7 | 68.7 | 70.2 | 11.7 |
| **Meta-Harness** | **53.3** | 67.0 | **60.0** | 94.0 | **46.0** | 82.7 | **86.7** | **91.3** | **77.3** | **73.1** | 7.3 |

Meta-Harness outperforms the next best method by 2.9 points on these 9 previously unseen tasks.

### 4.2 Harnesses for Retrieval-Augmented Reasoning

We study a setup for olympiad math solving: augmenting the model with the ability to retrieve examples from a large corpus. The retrieval corpus contains ≥500,000 solved problems from eight open-source datasets. We use Meta-Harness to optimize a harness for 40 iterations over a 250-problem search set of Olympiad-difficulty math problems (OlympiadBench + Omni-MATH hard), producing 109 candidate retrieval harnesses. We evaluate on 200 previously unseen IMO-level problems drawn from IMO-AnswerBench, IMO-ProofBench, and ArXivMath [30; 6].

**Table 6: Retrieval-augmented math problem solving on 200 IMO-level math problems.**

| Method | GPT-5.4n | GPT-5.4m | Gem-3.1FL | Gem-3F | GPT-20B | Avg. |
|--------|----------|----------|-----------|--------|---------|------|
| No Retriever | 23.0 | 28.8 | 28.6 | 42.6 | 47.6 | 34.1 |
| Dense Retrieval (k=1) | 27.1 (+4.1) | 24.5 (-4.3) | 31.3 (+2.7) | 42.3 (-0.3) | 46.9 (-0.7) | 34.4 (+0.3) |
| Dense Retrieval (k=5) | 31.1 (+8.1) | 28.3 (-0.5) | 37.1 (+8.5) | 47.2 (+4.6) | 46.7 (-0.9) | 38.1 (+4.0) |
| Random Few-shot | 23.1 (+0.1) | 24.5 (-4.3) | 31.0 (+2.4) | 40.4 (-2.2) | 41.8 (-5.8) | 32.2 (-1.9) |
| BM25 Retrieval | 30.2 (+7.2) | 29.2 (+0.4) | 32.8 (+4.2) | 46.6 (+4.0) | 48.9 (+1.3) | 37.5 (+3.4) |
| **Meta-Harness** | **31.7 (+8.7)** | **30.4 (+1.6)** | **34.9 (+6.3)** | 46.3 (+3.7) | **50.6 (+3.0)** | **38.8 (+4.7)** |

We show pass@1 averaged over three samples per problem, with absolute improvement over the baseline in parentheses. The discovered Meta-Harness retrieval strategy improves reasoning across all five held-out models, with a 4.7-point average gain over no retriever.

> **Meta-Harness Improves Reasoning on IMO-Level Math Problems**  
> In retrieval-augmented math reasoning, a single discovered retrieval harness transfers across five held-out models, improving accuracy by 4.7 points on average over no retrieval and yielding the strongest overall average among the compared methods.

### 4.3 Evaluating Agentic Coding Harnesses on TerminalBench-2

TerminalBench-2 [33] evaluates LLM agents on 89 challenging tasks that require long-horizon, fully autonomous execution under complex dependencies, and substantial domain knowledge. We initialize search from two strong open baselines, Terminus 2 [33] and Terminus-KIRA [25].

**Table 7: Pass rate on TerminalBench-2.**

| Harness | Auto | Pass (%) |
|---------|------|----------|
| **Claude Opus 4.6** | | |
| Claude Code | × | 58.0 |
| Terminus 2 | × | 62.9 |
| Mux | × | 66.5 |
| Droid | × | 69.9 |
| TongAgents | × | 71.9 |
| MAYA-V2 | × | 72.1 |
| Terminus-KIRA | × | 74.7 |
| Capy | × | 75.3 |
| **Meta-Harness** | ✓ | 76.4 |
| ForgeCode | × | 81.8 |
| **Claude Haiku 4.5** | | |
| OpenHands | × | 13.9 |
| Claude Code | × | 27.5 |
| Terminus 2 | × | 28.3 |
| Mini-SWE-Agent | × | 29.8 |
| Terminus-KIRA | × | 33.7 |
| Goose | × | 35.5 |
| **Meta-Harness** | ✓ | **37.6** |

Results for others are from the official leaderboard. Meta-Harness ranks #2 among all Opus-4.6 agents and #1 among all Haiku-4.5 agents on this competitive task.

On Opus 4.6, Meta-Harness discovers a harness achieving 76.4% pass rate, surpassing the hand-engineered Terminus-KIRA (74.7%) and ranking #2 among all Opus 4.6 agents. On the weaker Haiku 4.5 model, the improvement is larger: Meta-Harness achieves 37.6%, outperforming the next-best reported agent (Goose, 35.5%) by 2.1 points.

> **Meta-Harness Surpasses Hand-Engineered Agents on TerminalBench-2**  
> On TerminalBench-2, Meta-Harness automatically discovers harnesses that surpass Terminus-KIRA on Opus 4.6 and rank #1 among all Haiku 4.5 agents.

---

## 5 Discussion

Beyond outperforming existing harnesses, Meta-Harness has several practical advantages. Discovered harnesses generalize to out-of-distribution classification datasets (Table 5) and to unseen base models in the math setting (Table 6). A search run completes in a few hours of wall-clock time, yet produces readable, transferable strategies that can be reused across models, including future, stronger ones. Overfitting in code space is also more inspectable: brittle if-chains or hard-coded class mappings are visible on inspection in a way that weight-space overfitting is not.

More broadly, our results suggest that the main advantage of Meta-Harness is not just search over code, but search with selective access to prior diagnostic experience. The proposer is not limited to scalar rewards or fixed summaries; it can inspect raw code, execution traces, and prior failures, then use that information to form and test hypotheses about what to change.

Our findings reflect a recurring pattern in machine learning [45]: once a search space becomes accessible, stronger general-purpose agents can outperform hand-engineered solutions. A natural next step for future work is to co-evolve the harness and the model weights, letting the strategy shape what the model learns and vice versa. While we evaluate on three diverse domains, our experiments demonstrate that harness search can work with one particularly strong coding-agent proposer (Claude Code); a broader study of how the effect varies across proposer agents remains for future work.

---

## Acknowledgements

We thank KRAFTON AI for providing API credit support. This work is supported by OpenAI, KFAS, and Schmidt Sciences AI2050. We thank Anikait Singh and Jubayer Ibn Hamid for their valuable feedback and suggestions, and Sienna J. Lee for patiently listening to YL's half-formed thoughts during the early stages of this work.

---

## References

[1] Lakshya A Agrawal et al. GEPA: Reflective prompt evolution can outperform reinforcement learning. *arXiv:2507.19457*, 2025.

[2] Ekin Akyurek et al. What learning algorithm is in-context learning? Investigations with linear models, 2023. https://arxiv.org/abs/2211.15661

[3] Marcin Andrychowicz et al. Learning to learn by gradient descent by gradient descent. *NeurIPS*, 29, 2016.

[4] Anthropic. Claude code: An agentic coding tool. https://www.anthropic.com/claude-code, 2025.

[5] Anthropic and community contributors. agentskills/agentskills. https://github.com/agentskills/agentskills, accessed March 27, 2026.

[6] Mislav Balunovic et al. Matharena: Evaluating LLMs on uncontaminated math competitions, February 2025. https://matharena.ai/

[7] Francesco Barbieri et al. TweetEval: Unified benchmark and comparative evaluation for tweet classification, 2020. https://arxiv.org/abs/2010.12421

[8] Luca Beurer-Kellner et al. Prompting is programming: A query language for large language models. *PLDI*, 2023.

[9] Birgitta Böckeler. Harness engineering. https://martinfowler.com/articles/exploring-gen-ai/harness-engineering.html, March 2026.

[10] Can Bölük. I improved 15 LLMs at coding in one afternoon. Only the harness changed. https://blog.can.ac/2026/02/12/the-harness-problem/, February 2026.

[11] Inigo Casanueva et al. Efficient intent detection with dual sentence encoders, 2020. https://arxiv.org/abs/2003.04807

[12] Mert Cemri et al. AdaEvolve: Adaptive LLM driven zeroth-order optimization. *arXiv:2602.20133*, 2026.

[13] Harrison Chase. LangChain, October 2022. https://github.com/langchain-ai/langchain

[14] Arman Cohan et al. Structural scaffolds for citation intent classification in scientific publications, 2019. https://arxiv.org/abs/1904.01608

[15] Dorottya Demszky et al. GoEmotions: A dataset of fine-grained emotions, 2020. https://arxiv.org/abs/2005.00547

[16] Zhiwei Fei et al. LawBench: Benchmarking legal knowledge of large language models. *EMNLP 2024*, pp. 7933–7962.

[17] Chelsea Finn, Pieter Abbeel, and Sergey Levine. Model-agnostic meta-learning for fast adaptation of deep networks. *ICML*, 2017.

[18] ForgeCode. Benchmarks don't matter, 2025. https://forgecode.dev/blog/benchmarks-dont-matter/

[19] Gretel AI. Symptom to diagnosis dataset. https://huggingface.co/datasets/gretelai/symptom_to_diagnosis, 2023.

[20] Shengran Hu, Cong Lu, and Jeff Clune. Automated design of agentic systems. *ICLR 2025*. https://openreview.net/forum?id=t9U3LW7JVX

[21] Anthropic Justin Young. Effective harnesses for long-running agents. https://anthropic.com/engineering/effective-harnesses-for-long-running-agents, November 2025.

[22] Phillip Keung et al. The multilingual Amazon reviews corpus, 2020. https://arxiv.org/abs/2010.02573

[23] Omar Khattab et al. DSPy: Compiling declarative language model calls into self-improving pipelines, 2023. https://arxiv.org/abs/2310.03714

[24] Tushar Khot et al. SciTail: A textual entailment dataset from science question answering. *AAAI*, 2018.

[25] KRAFTON AI and Ludo Robotics. Terminus-KIRA: Boosting frontier model performance on terminal-bench with minimal harness, 2026. https://github.com/krafton-ai/kira

[26] Yoonho Lee, Joseph Boen, and Chelsea Finn. Feedback descent: Open-ended text optimization via pairwise comparison. *arXiv:2511.07919*, 2025.

[27] Joel Lehman et al. Evolution through large models, 2022. https://arxiv.org/abs/2206.08896

[28] Patrick Lewis et al. Retrieval-augmented generation for knowledge-intensive NLP tasks. *NeurIPS*, 33:9459–9474, 2020.

[29] Lefteris Loukas et al. FiNER: Financial numeric entity recognition for XBRL tagging. *ACL 2022*, pp. 4419–4431.

[30] Thang Luong et al. Towards robust mathematical reasoning. *EMNLP 2025*. https://aclanthology.org/2025.emnlp-main.1794/

[31] Aman Madaan et al. Self-refine: Iterative refinement with self-feedback. *NeurIPS*, 36:46534–46594, 2023.

[32] Pekka Malo et al. Good debt or bad debt: Detecting semantic orientations in economic texts, 2013. https://arxiv.org/abs/1307.5336

[33] Mike A Merrill et al. TerminalBench: Benchmarking agents on hard, realistic tasks in command line interfaces. *arXiv:2601.11868*, 2026.

[34] Jack Nichols. How we scored #1 on terminal-bench (52%), Jun 2025. https://www.warp.dev/blog/terminal-bench

[35] Alexander Novikov et al. AlphaEvolve: A coding agent for scientific and algorithmic discovery. *arXiv:2506.13131*, 2025.

[36] OpenAI. Harness engineering: Leveraging Codex in an agent-first world. https://openai.com/index/harness-engineering/, February 2026.

[37] Charles Packer et al. MemGPT: Towards LLMs as operating systems, 2023.

[38] Reid Pryzant et al. Automatic prompt optimization with "gradient descent" and beam search. *arXiv:2305.03495*, 2023.

[39] Bernardino Romera-Paredes et al. Mathematical discoveries from program search with large language models. *Nature*, 625(7995):468–475, 2024.

[40] Jurgen Schmidhuber. A neural network that embeds its own meta-levels. *IEEE ICNN*, 1993.

[41] Nadine Schneider et al. What's what: The (nearly) definitive guide to reaction role assignment. *J. Chemical Information and Modeling*, 56(12):2336–2346, 2016.

[42] Srijan Shakya et al. Adaptive retrieval helps reasoning in LLMs – but mostly if it's not used, 2026. https://arxiv.org/abs/2602.07213

[43] Asankhaya Sharma. OpenEvolve: An open-source evolutionary coding agent. https://github.com/algorithmicsuperintelligence/openevolve, 2025.

[44] Jake Snell, Kevin Swersky, and Richard S. Zemel. Prototypical networks for few-shot learning. *NeurIPS*, 2017.

[45] Rich Sutton. The bitter lesson, 2019.

[46] Sebastian Thrun and Lorien Pratt. Learning to learn: Introduction and overview. In *Learning to learn*, pp. 3–17. Springer, 1998.

[47] Muxin Tian et al. SWE-bench mobile: Can large language model agents develop industry-level mobile applications? *arXiv*, 2026.

[48] Harsh Trivedi et al. Interleaving retrieval with chain-of-thought reasoning for knowledge-intensive multi-step questions, 2023. https://arxiv.org/abs/2212.10509

[49] Chenghao Xiao et al. RAR-B: Reasoning as retrieval benchmark, 2024. https://arxiv.org/abs/2404.06347

[50] Yiming Xiong, Shengran Hu, and Jeff Clune. Learning to continually learn via meta-learning agentic memory designs. *OpenReview*, 2026.

[51] Chengrun Yang et al. Large language models as optimizers. *ICLR 2023*.

[52] Haoran Ye et al. Meta context engineering via agentic skill evolution. *arXiv:2601.21557*, 2026.

[53] Mert Yuksekgonul et al. TextGrad: Automatic "differentiation" via text, 2024. https://arxiv.org/abs/2406.07496

[54] Mert Yuksekgonul et al. Learning to discover at test time, 2026. https://arxiv.org/abs/2601.16175

[55] Mert Yuksekgonul et al. Learning to discover at test time. *arXiv:2601.16175*, 2026.

[56] Alex L. Zhang, Tim Kraska, and Omar Khattab. Recursive language models, 2026. https://arxiv.org/abs/2512.24601

[57] Guibin Zhang et al. MemEvolve: Meta-evolution of agent memory systems. *arXiv:2512.18746*, 2025.

[58] Jiayi Zhang et al. AFlow: Automating agentic workflow generation, 2025. https://arxiv.org/abs/2410.10762

[59] Qizheng Zhang et al. Agentic context engineering: Evolving contexts for self-improving language models. *arXiv:2510.04618*, 2025.

[60] Xiang Zhang, Junbo Zhao, and Yann LeCun. Character-level convolutional networks for text classification, 2016. https://arxiv.org/abs/1509.01626

---

## Appendix A: Qualitative Proposer Behavior

This section examines how the proposer uses the filesystem during search, drawing on the TerminalBench-2 run (10 iterations, Claude Opus 4.6).

### A.1 File Access Statistics

**Table 8: Proposer file access statistics from the TerminalBench-2 search run.**

| Statistic | Value |
|-----------|-------|
| Files read per iteration (median) | 82 |
| Files read per iteration (range) | 69–99 |
| **File type breakdown** | |
| Harness source code | 41% |
| Execution traces | 40% |
| Score/summary files | 6% |
| Other | 13% |

The proposer reads a median of 82 files per iteration (range 69–99), roughly evenly split between prior harness source code (41%) and execution traces (40%). This confirms that the proposer's access pattern is non-Markovian: it routinely inspects the majority of available history rather than conditioning only on the most recent parent.

### A.2 Qualitative Behavior: Causal Reasoning Over Prior Failures

The TerminalBench-2 search log reveals a clear narrative arc in which the proposer learns from its own regressions.

**Iterations 1–2: promising bugfixes are confounded by prompt edits.** The first two iterations both bundle plausible structural fixes with prompt-template modifications, and both regress sharply from the 64.4% Terminus-KIRA baseline. Iteration 1 targets observation corruption from leaked terminal markers and adds a loop breaker:

> *"Hypothesis: CMDEND marker fragments leak into LLM observations on long-running tasks, causing the model to get confused and enter infinite no-tool-call loops. Stripping these markers + adding a loop breaker will recover wasted steps."*

Iteration 2 proposes a different state-machine fix:

> *"Double-confirmation completion mechanism causes verification spirals. Observed in trajectories where the agent solves the task early but burns 15--40+ additional steps re-verifying because each verification command resets pending completion, requiring another task complete → checklist → verify cycle."*

**Iteration 3: the proposer identifies the confound.** By iteration 3, the proposer explicitly infers that the regressions are not primarily due to the structural bugfixes themselves:

> *"Prior attempts: evo marker fix (58.9%, -5.6pp), evo single confirm (57.8%, -6.7pp) --- both regressed. Root cause of regressions: Prompt template changes (cleanup directives) caused the agent to delete necessary state before task completion. The structural bugfixes were confounded with harmful prompt changes. evo strip only isolates the two proven structural fixes."*

**Iterations 4–6: direct fixes to the diagnosed failure mode still regress.** Iteration 4 attributes failures to a concrete state-machine bug:

> *"Remove the two `self.pending_completion = False` lines that reset the completion flag when intermediate commands run. This fixes a state machine bug where: (1) Agent calls `task_complete` → sees QA checklist, `pending_completion = True` (2) Agent runs verification commands → `pending_completion = False` (bug!) (3) Agent calls `task_complete` again → sees checklist AGAIN → infinite loop."*

**Iteration 7: the winning candidate.** After six consecutive regressions, the proposer shifts strategy:

> *"All 6 prior iterations regressed from the 64.4% baseline because they modified the completion flow, prompt template, or observation processing. evo env bootstrap takes a different approach --- purely additive. It gathers an environment snapshot via a single shell command before the first LLM call and appends it to the initial prompt. No other methods are changed. This should eliminate 3--5 wasted exploration turns on dependency-heavy tasks without risking regression on already-passing tasks."*

**Iteration 8: composition.** Having found one additive improvement, the proposer next attempts to compose it with an earlier structural fix:

> *"Combining two orthogonal fixes --- env snapshot (saves early exploration turns) + marker stripping with no-tool-call loop breaker --- will yield +1--3pp because they address independent failure modes without touching prompts or confirmation flows (which caused regressions in 5 of 7 prior iterations)."*

**Summary.** The search trajectory demonstrates that the proposer does more than random mutation. Across the first seven iterations, it identifies a confound, tests the confound-isolating hypothesis directly, observes that control-flow and prompt edits remain fragile, and then deliberately pivots to a purely additive modification that becomes the best candidate in the run.

---

## Appendix B: Discovered Harnesses

### B.1 Text Classification Harness

In online text classification, Meta-Harness discovers a family of memory-based harnesses. Table 9 reports the Pareto frontier of non-dominated variants.

**Table 9: Pareto-optimal discovered variants from the main text-classification search.**

| Variant | USPTO ↑ | Symptom ↑ | LawBench ↑ | Avg ↑ | Ctx ↓ |
|---------|---------|-----------|------------|-------|--------|
| Meta-Harness (Draft Verification) | 18.0 | 85.4 | 17.0 | 40.1 | 5.4 |
| Meta-Harness (Error-Annotated) | 9.0 | 87.7 | 24.0 | 40.2 | 22.3 |
| Meta-Harness (CoT Replay) | 13.0 | 88.2 | 25.0 | 42.1 | 23.3 |
| Meta-Harness (Cluster Coverage) | 12.0 | 86.8 | 33.0 | 43.9 | 31.2 |
| Meta-Harness (Cascade Retrieval) | 12.0 | 86.8 | 36.0 | 44.9 | 39.2 |
| Meta-Harness (RRF + Contrastive) | 18.0 | 89.6 | 35.0 | 47.5 | 41.4 |
| Meta-Harness (Relevance + Contrastive) | 18.0 | 90.6 | 36.0 | 48.2 | 43.9 |
| Meta-Harness (Label-Primed Query) | 14.0 | 86.8 | 45.0 | 48.6 | 45.5 |

Ctx denotes average additional characters in input context (thousands).

**Meta-Harness (Draft Verification).** This lightweight variant turns prediction into a two-call procedure:
- **Stage 1: Draft.** Retrieve the 5 nearest labeled examples and ask for an initial prediction.
- **Stage 2: Verification.** Condition retrieval on the draft label, then show both supporting and challenging examples before making the final prediction.
- **Cold start.** If fewer than 5 labeled examples are available, use a standard single-call few-shot prompt.

**Meta-Harness (Label-Primed Query).** This strongest variant uses a single larger call built from three parts:
- **Label primer.** List the valid output labels before showing any examples.
- **Coverage block.** For each known label, retrieve the most query-relevant labeled example.
- **Contrastive block.** Build pairs of highly similar examples with different labels to expose local decision boundaries.
- **Retrieval rule.** Use TF-IDF similarity and query-anchored partner selection rather than label-agnostic nearest neighbors.

### B.2 Math Retrieval Harness

The final harness is a compact four-route BM25 program. At inference time, the harness assigns each problem to exactly one of four routes: combinatorics, geometry, number theory, or a default route for algebra and other problems. The BM25 index uses a math-aware tokenizer that preserves LaTeX tokens (e.g., `\frac`, `^{2}`) as atomic units.

- **Combinatorics:** fetch 20 BM25 candidates, deduplicate to 8, rerank by lexical score and difficulty, then return the top 3.
- **Geometry:** return 1 hard NuminaMath reference together with 2 raw BM25 neighbors.
- **Number theory:** fetch 12 BM25 candidates and rerank using lexical score, difficulty, and a small bonus for solutions that state a technique early.
- **Default:** fetch 10 BM25 candidates, rerank by lexical score and difficulty, and choose an adaptive number of examples based on how concentrated the top retrieval scores are.

### B.3 TerminalBench-2 Harness

The discovered TerminalBench-2 harness builds on Terminus-KIRA [25], inheriting its native tool calling, 30KB output cap, and multi-perspective completion checklist. The main modification discovered by Meta-Harness is **environment bootstrapping**: before the agent loop begins, the harness runs a compound shell command to gather a snapshot of the sandbox environment and injects it into the initial prompt.

The snapshot includes: the working directory, a listing of `/app` (truncated to 20 entries for large directories), available programming languages and their versions (Python, GCC, G++, Node, Java, Rust, Go), installed package managers (pip, apt-get), and available memory. This eliminates the 2–4 exploratory turns that agents typically spend discovering what tools and files are available. The bootstrapping command is guarded by a 15-second timeout and fails silently. The full implementation adds roughly 80 lines on top of Terminus-KIRA.

---

## Appendix C: Dataset Details

### C.1 OOD Text Classification Datasets

- **SciCite**: 3-way citation-intent classification from scientific papers (background, method, or result).
- **FiNER-139**: Financial numeric entity recognition with 139 fine-grained XBRL entity types from financial filings.
- **Amazon Reviews**: 5-way review rating prediction from the Multilingual Amazon Reviews Corpus.
- **Financial PhraseBank**: 3-way financial sentiment classification (positive, neutral, negative) from financial news.
- **GoEmotions**: Fine-grained emotion classification from English Reddit comments (28 categories).
- **Banking77**: Fine-grained intent classification with 77 intents from online banking utterances.
- **AG News**: 4-way news topic classification (world, sports, business, science/technology).
- **SciTail**: Science-domain textual entailment benchmark.
- **TweetEval (Hate)**: Binary hate-speech detection from tweets.

### C.2 Math Retrieval Corpus

**Table 10: Datasets in the math retrieval corpus (535K problems total).**

| Dataset | Problems | Sol. Len | Proof |
|---------|----------|----------|-------|
| OpenMathReasoning | 281,743 | 5,000† | 34% |
| DeepMath-103K | 103,021 | 5,000† | 0% |
| NuminaMath-1.5 | 129,520 | 1,376 | 13% |
| PolyMath | 11,083 | 363 | 0% |
| Omni-MATH | 4,289 | 829 | 0% |
| FineProofs-SFT | 4,275 | 3,977 | 100% |
| AIME 1983–2024 | 933 | — | 0% |
| Putnam-AXIOM | 492 | 888 | 100% |
| **Total** | **535,356** | 5,000† | 22% |

† Truncated at 5,000 characters; actual solutions are longer. Sol. Len is the median solution length in characters.

### C.3 Math IMO-level Test Set

**Table 11: Breakdown of the 200-problem IMO-level evaluation set.**

| Dataset | Problems |
|---------|----------|
| IMO-AnswerBench | 100 |
| IMO-ProofBench | 60 |
| ArXivMath Dec. 2025 | 17 |
| ArXivMath Jan. 2026 | 23 |
| **Total** | **200** |

---

## Appendix D: Practical Implementation Tips

Meta-Harness is largely domain-agnostic. The following guidelines are engineering lessons from building and running the system:

- **Write a good skill.** The skill text is the primary interface for steering the search. It should specify what is forbidden, what artifacts to produce, and what objectives to optimize, while leaving the model free to inspect scores, traces, and prior code as needed. Iterating on the skill text had a larger effect on search quality than changing iteration count or population size. Run a few short evolution runs (3–5 iterations each) specifically to debug and refine the skill before committing to a full run.

- **Start with a baseline harness and a search set that is hard for it.** Write a simple baseline (e.g., few-shot prompting), then construct the search set by filtering for examples the baseline gets wrong or selecting a diverse subset of difficult instances. Keep the search set small enough for roughly 50 full evaluations per run (50–100 examples in classification experiments, 88 problems for math retrieval).

- **Log everything in a format that is easy to navigate.** Use machine-readable formats such as JSON, organize artifacts hierarchically, choose reasonable and consistent file names, and adopt naming schemes that make simple tools such as regex search work well.

- **Make logs queryable through a small CLI (optional, but helpful).** A short CLI that lists the Pareto frontier, shows top-k harnesses, and diffs code and results between pairs of runs can make the experience store much easier to use.

- **Lightweight validation before expensive benchmarks.** Write a small validation test that imports the module, instantiates the class, and calls both methods on a tiny set of examples. A simple test script can catch most malformed or nonfunctional candidates in seconds.

- **Automate evaluation outside the proposer.** Running evals is simple enough that it is not worth making the proposer do it. A separate harness should score candidates and write results to the filesystem.

---

## Appendix E: Extended Related Work

**AlphaEvolve / OpenEvolve.** AlphaEvolve [35] and OpenEvolve [43] evolve code via LLM-guided mutations with structured feedback. These methods are designed for algorithm discovery and optimization (mathematical conjectures, scheduling heuristics, hardware kernels), where the search target is a single stateless function. Harness engineering is a different regime: harnesses are stateful programs that accumulate experience across many examples, and a single design choice can cascade through an entire evaluation sequence.

**GEPA.** GEPA [1] is the closest text optimizer in terms of feedback richness, providing rollout traces per candidate. It is designed for prompt optimization on tasks with short feedback loops. Harness engineering requires reasoning across many examples and many candidates simultaneously. GEPA operates on one candidate at a time (2–8K tokens per step), with a fixed critique format. Meta-Harness gives the proposer access to all prior candidates simultaneously.

**Prompt orchestration frameworks.** LMQL [8], LangChain [13], and DSPy [23] make prompt engineering more systematic by providing higher-level interfaces for prompt templates, control flow, and modular LLM pipelines. These frameworks help developers specify and organize LLM programs, but still require manual design of retrieval policies, memory updates, and orchestration logic. Meta-Harness operates at a different level: it searches over the *implementation* of these policies in executable code, treating the harness itself as the optimization target.
