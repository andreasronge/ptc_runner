# Hyperagents: A New Way to Auto-Research

See [godel-machine.pdf](./godel-machine.pdf) or [hyper-agents.md](./hyper-agents.md)

## Overview

"**Hyperagents**" is a new framework for building self-improving AI systems. Created by Meta AI and a bunch of top universities, this approach is like Dr. Karpathy's auto-research, but with recursive tree exploration wrapped in a Darwin-Godel Machine.

The core idea is to move away from systems that have a fixed, human-engineered way of learning and instead create agents that can redesign their own improvement mechanisms.

## Traditional Self-Improving Systems

Traditionally, self-improving systems consist of two parts:
- **Task agent**: which performs the actual work, like writing code or solving math
- **Meta agent**: a higher-level system that modifies the task agent to make it better

The problem is that the meta agent's logic is usually fixed by human engineers, which eventually limits how much the system can improve. What if we just give up this control, and let the AI take care of the learning and the task-ing on its own?

What if you could recursively let agents explore improvement strategies, kind of like a tree?

## The Role of the Human

Humans have a nasty habit of inserting themselves into how agents should learn. The classic term for this is "inductive bias"—the specific rules, structures, and improvement mechanisms that help an agent learn.

In the Hyperagents framework, the system is designed to automate this engineering process itself. Based on the paper, the human's role transitions into these four key areas:

- **Defining the "What," Not the "How"**: Humans are responsible for defining the benchmarks and evaluation criteria. The agent is given a goal (e.g., "grade this math problem correctly"), but it is left to autonomously discover the "how".

- **Safety**: Humans oversee that the agent operates within a sandboxed environment with strict resource limits (timeouts, internet restrictions) to prevent unintended side effects from autonomous code modification.

- **Datasets**: Humans input whatever data and eval criteria that the agent uses.

## What Are Hyperagents?

A "hyperagent" is a fancy term for a self-referential agent that integrates both the task agent and the meta agent into a single editable program. Because the meta agent is itself part of the editable code, the system can perform "metacognitive self-modification."

Metacognitive self-modification is a fancy way of saying that the agent doesn't just look for better ways to solve a task. It looks for better ways to look for better ways.

The authors propose **DGM-H** (Darwin Gödel Machine - Hyperagents), an extension of the original Darwin Gödel Machine (DGM).

## Darwin Gödel Machine Explained

The **Darwin Gödel Machine (DGM)** is an AI framework for creating self-improving AI systems that "evolve" their own code over time. Its name is derived from two concepts: **Darwinian evolution** plus **Gödelian self-reference**.

### The Darwinian Aspect

Refers to the system's use of open-ended exploration and population-based evolution. It traditionally works in 3 stages:

1. **Generation**: The system starts with an initial agent and generates multiple variants (children) of that agent by modifying its code.
2. **Selection**: These variants are then empirically evaluated on a task.
3. **Archive of Stepping Stones**: Successful versions are saved in an archive. These serve as "stepping stones"—parent agents that the system can later select to generate even better descendants.

### The Gödel Self-Reference Part

Refers to the system being self-referential. The agent that solves the task (the task agent) is the exact same code that is responsible for generating its own improvements (the meta agent). It updates its own source code—a program that "edits itself."

## The Algorithm (DGM-H)

### 1. The Hyperagent Structure

At the core of the algorithm is the **Hyperagent (H)**, which is a unified, editable program consisting of two functional components:

- **Task Agent**: The code responsible for solving the target domain task (e.g., writing a robotic reward function or solving a math problem).
- **Meta Agent**: Responsible for generating improvements. It can edit the source code of both the task agent and itself.

### 2. The Loop

The algorithm maintains an archive of "stepping stones" where each element is a scored hyperagent. These "stepping stones" are basically code files that worked previously.

The core optimization loop follows these steps:

1. **Parent Selection**: A parent hyperagent is sampled from the archive based on its performance and its "fertility" (how many successful children it has already produced).

2. **Metacognitive Self-Modification**: The selected parent uses its internal Meta Agent to generate a child variant. Because the Meta Agent is part of the editable codebase, the child may have a different strategy for self-improvement than its parent.

3. **Evaluation**: The child is tested on the target task. Its performance score is recorded.

4. **Archive Update**: This new child agent is added to the archive. This ensures that the system doesn't just keep the best agent but maintains a diverse population to avoid local optima.

### Interacting with Source Code

The hyperagent interacts with its own source code through a **bash tool**. This tool allows the Meta Agent to:
- **view**: Read current file content
- **create**: Generate new script files
- **str_replace & insert**: Directly edit existing Python files in the repository

### 3. Exploration vs. Exploitation

To balance exploration and exploitation, DGM-H uses a probabilistic selection mechanism—like a talent scout that decides which agents in the archive deserve a chance to "reproduce."

It uses two main rules:

- **Reward Success (Exploitation)**: Agents that have high performance scores are more likely to be chosen, ensuring the system keeps building on its best ideas.
- **Punish "Over-breeding" (Exploration)**: If an agent has already produced many successful children, the system lowers its priority, forcing it to try other promising agents instead.

## Some Results

For various tasks, they used different models (o3-mini, sonnet-3.5, etc.). For a standard 100-iteration run, the costs were broken down as follows:

- **Self-Modification Phase**: ~33M tokens (the Meta Agent reading its codebase, analyzing logs, and writing new code)
- **Task Evaluation Phase**: ~50.6M tokens (the Task Agent performing the actual work)
- **Total Cost per Run**: ~88.6 Million tokens

For Sonnet models, that would be around $500 spent per experiment.

They showed cool improvements in:
- Olympiad-Level Math Grading
- Robotics Reward Design
- Paper Reviewing

### Example: Self-Instruction Logic

The Meta Agent modified its own `task_agent.py` to include adaptive self-instruction based on iterations remaining, adjusting its strategy accordingly.

### Example: Adaptive Exploration

The agent discovered logic to detect when it was "stuck" and increase exploration if performance stalled.

### Example: Sanity Checks

The agent developed internal checks to ensure it wasn't becoming biased toward a single answer, analyzing its own label distribution to detect "all-or-nothing" grading.

### Example: Performance Tracking

The agent autonomously created infrastructure to track its own history across generations to avoid repeating mistakes.

### Example: Self-Generated Improvements Log

The agent began writing its own "diary" of technical insights, documenting problems identified, root cause analysis, and action plans.

## Is Software Engineering Dead?

The Hyperagent framework embodies the principles in Richard Sutton's "The Bitter Lesson." That essay points out that the history of AI research shows that human-designed "cleverness" (inductive bias) is eventually always overtaken by general methods that leverage computation (search and learning).

Examples:
- Alpha Go Zero trained from scratch with RL beat Alpha Go, which was pretrained on human Go games
- Vision Transformers with their general attention mechanism beat CNNs in image classification tasks

The paper suggests that we're reaching a point where even the mechanism of self-improvement itself should not be human-designed. By making the "meta-logic" part of the compute-driven search process, AI systems can surpass the boundaries defined by the meta agent's [human] design.

## Conclusion

The pattern of self-improvement (alpha-evolve, auto-research, hyperagents) represents one of the most amazing capability breakthroughs in AI history. Humans have more important things to do than write low-level code—this is an evolution opportunity, not a regression.

