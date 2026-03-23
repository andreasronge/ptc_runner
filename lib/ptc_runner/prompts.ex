defmodule PtcRunner.Prompts do
  @moduledoc """
  Centralized prompt loading for PtcRunner.

  All prompt templates are loaded from `priv/prompts/` at compile time and
  exposed through this module. Changes to prompt files trigger recompilation.

  ## Prompt Files (2-Axis Architecture)

  Language specs are composed from two axes plus optional capabilities:

  | Axis | File | Function |
  |------|------|----------|
  | Reference | `reference.md` | `reference/0` |
  | Behavior | `behavior-single-shot.md` | `behavior_single_shot/0` |
  | Behavior | `behavior-multi-turn.md` | `behavior_multi_turn/0` |
  | Return mode | `behavior-return-explicit.md` | `behavior_return_explicit/0` |
  | Return mode | `behavior-return-auto.md` | `behavior_return_auto/0` |
  | Capability | `capability-journal.md` | `capability_journal/0` |
  | Standalone | `lisp-addon-repl.md` | `repl/0` |

  ## Other Prompt Files

  | File | Function | Used By |
  |------|----------|---------|
  | `json-system.md` | `json_system/0` | `JsonMode` |
  | `json-user.md` | `json_user/0` | `JsonMode` |
  | `json-error.md` | `json_error/0` | `JsonMode` |
  | `tool-calling-system.md` | `tool_calling_system/0` | `ToolCallingMode` |
  | `must_return_warning.md` | `must_return_warning/0` | `TurnFeedback` |
  | `retry_feedback.md` | `retry_feedback/0` | `TurnFeedback` |
  | `planning-examples.md` | `planning_examples/0` | `MetaPlanner` |
  | `verification-predicate-guide.md` | `verification_guide/0` | `MetaPlanner` |
  | `verification-predicate-reminder.md` | `verification_reminder/0` | `MetaPlanner` |

  ## File Format

  Prompt files use HTML comment markers to separate metadata from content:

      # Title
      Description for maintainers.

      <!-- version: 1 -->
      <!-- date: 2026-01-01 -->

      <!-- PTC_PROMPT_START -->
      Actual prompt content here.
      <!-- PTC_PROMPT_END -->

  Content between `PTC_PROMPT_START` and `PTC_PROMPT_END` markers is extracted.
  If no markers exist, the entire file (trimmed) is used.

  ## Mustache Templates

  Some prompts use Mustache templating (e.g., `must_return_warning.md`):

  - `{{variable}}` - Simple substitution
  - `{{#section}}...{{/section}}` - Conditional/iteration
  - `{{^section}}...{{/section}}` - Inverted (if falsy)

  See `PtcRunner.Mustache` for expansion.

  ## Adding New Prompts

  1. Create `priv/prompts/my-prompt.md` with markers
  2. Add to this module:
     - `@my_prompt_file` path
     - `@external_resource @my_prompt_file`
     - `@my_prompt` loaded content
     - `def my_prompt, do: @my_prompt`
  3. Document in the table above
  """

  alias PtcRunner.PromptLoader

  @prompts_dir Path.join(:code.priv_dir(:ptc_runner), "prompts")

  # ============================================================================
  # PTC-Lisp Language Specs — New 2-Axis Components
  # ============================================================================

  @reference_file Path.join(@prompts_dir, "reference.md")
  @behavior_single_shot_file Path.join(@prompts_dir, "behavior-single-shot.md")
  @behavior_multi_turn_file Path.join(@prompts_dir, "behavior-multi-turn.md")
  @behavior_return_explicit_file Path.join(@prompts_dir, "behavior-return-explicit.md")
  @behavior_return_auto_file Path.join(@prompts_dir, "behavior-return-auto.md")
  @capability_journal_file Path.join(@prompts_dir, "capability-journal.md")

  @external_resource @reference_file
  @external_resource @behavior_single_shot_file
  @external_resource @behavior_multi_turn_file
  @external_resource @behavior_return_explicit_file
  @external_resource @behavior_return_auto_file
  @external_resource @capability_journal_file

  @reference @reference_file |> File.read!() |> PromptLoader.extract_with_header()
  @behavior_single_shot @behavior_single_shot_file
                        |> File.read!()
                        |> PromptLoader.extract_with_header()
  @behavior_multi_turn @behavior_multi_turn_file
                       |> File.read!()
                       |> PromptLoader.extract_with_header()
  @behavior_return_explicit @behavior_return_explicit_file
                            |> File.read!()
                            |> PromptLoader.extract_with_header()
  @behavior_return_auto @behavior_return_auto_file
                        |> File.read!()
                        |> PromptLoader.extract_with_header()
  @capability_journal @capability_journal_file
                      |> File.read!()
                      |> PromptLoader.extract_with_header()

  @doc "Language reference: tool syntax, Java interop, restrictions."
  @spec reference() :: String.t()
  def reference, do: elem(@reference, 1)

  @doc "Raw header + content for reference.md."
  @spec reference_with_header() :: {String.t(), String.t()}
  def reference_with_header, do: @reference

  @doc "Single-shot behavior: last expression is the answer, one turn."
  @spec behavior_single_shot() :: String.t()
  def behavior_single_shot, do: elem(@behavior_single_shot, 1)

  @doc "Raw header + content for behavior-single-shot.md."
  @spec behavior_single_shot_with_header() :: {String.t(), String.t()}
  def behavior_single_shot_with_header, do: @behavior_single_shot

  @doc "Shared multi-turn core: one code block per turn, state, short programs."
  @spec behavior_multi_turn() :: String.t()
  def behavior_multi_turn, do: elem(@behavior_multi_turn, 1)

  @doc "Raw header + content for behavior-multi-turn.md."
  @spec behavior_multi_turn_with_header() :: {String.t(), String.t()}
  def behavior_multi_turn_with_header, do: @behavior_multi_turn

  @doc "Explicit return fragment: use (return ...) / (fail ...)."
  @spec behavior_return_explicit() :: String.t()
  def behavior_return_explicit, do: elem(@behavior_return_explicit, 1)

  @doc "Raw header + content for behavior-return-explicit.md."
  @spec behavior_return_explicit_with_header() :: {String.t(), String.t()}
  def behavior_return_explicit_with_header, do: @behavior_return_explicit

  @doc "Auto-return fragment: println=continue, no println=answer."
  @spec behavior_return_auto() :: String.t()
  def behavior_return_auto, do: elem(@behavior_return_auto, 1)

  @doc "Raw header + content for behavior-return-auto.md."
  @spec behavior_return_auto_with_header() :: {String.t(), String.t()}
  def behavior_return_auto_with_header, do: @behavior_return_auto

  @doc "Journal capability: task caching, step-done, semantic progress."
  @spec capability_journal() :: String.t()
  def capability_journal, do: elem(@capability_journal, 1)

  @doc "Raw header + content for capability-journal.md."
  @spec capability_journal_with_header() :: {String.t(), String.t()}
  def capability_journal_with_header, do: @capability_journal

  # ============================================================================
  # PTC-Lisp REPL Mode (standalone, not part of 2-axis composition)
  # ============================================================================

  @repl_file Path.join(@prompts_dir, "lisp-addon-repl.md")
  @external_resource @repl_file
  @repl @repl_file |> File.read!() |> PromptLoader.extract_with_header()

  @doc "REPL mode (one expression per turn, incremental exploration)."
  @spec repl() :: String.t()
  def repl, do: elem(@repl, 1)

  @doc "Raw header + content for lisp-addon-repl.md."
  @spec repl_with_header() :: {String.t(), String.t()}
  def repl_with_header, do: @repl

  # ============================================================================
  # Text Mode (JSON variant) Templates
  # ============================================================================

  @json_system_file Path.join(@prompts_dir, "json-system.md")
  @json_user_file Path.join(@prompts_dir, "json-user.md")
  @json_error_file Path.join(@prompts_dir, "json-error.md")

  @external_resource @json_system_file
  @external_resource @json_user_file
  @external_resource @json_error_file

  @json_system @json_system_file |> File.read!() |> PromptLoader.extract_content()
  @json_user @json_user_file |> File.read!() |> PromptLoader.extract_content()
  @json_error @json_error_file |> File.read!() |> PromptLoader.extract_content()

  @doc "Text mode (JSON variant) system prompt."
  @spec json_system() :: String.t()
  def json_system, do: @json_system

  @doc "Text mode (JSON variant) user message template (Mustache)."
  @spec json_user() :: String.t()
  def json_user, do: @json_user

  @doc "Text mode (JSON variant) error feedback template (Mustache)."
  @spec json_error() :: String.t()
  def json_error, do: @json_error

  # ============================================================================
  # Tool Calling Mode Templates
  # ============================================================================

  @tool_calling_system_file Path.join(@prompts_dir, "tool-calling-system.md")

  @external_resource @tool_calling_system_file

  @tool_calling_system @tool_calling_system_file |> File.read!() |> PromptLoader.extract_content()

  @doc "Tool calling mode system prompt."
  @spec tool_calling_system() :: String.t()
  def tool_calling_system, do: @tool_calling_system

  # ============================================================================
  # Turn Feedback Templates
  # ============================================================================

  @must_return_warning_file Path.join(@prompts_dir, "must_return_warning.md")
  @retry_feedback_file Path.join(@prompts_dir, "retry_feedback.md")

  @external_resource @must_return_warning_file
  @external_resource @retry_feedback_file

  @must_return_warning @must_return_warning_file
                       |> File.read!()
                       |> PromptLoader.extract_content()
  @retry_feedback @retry_feedback_file |> File.read!() |> PromptLoader.extract_content()

  @doc """
  Final work turn warning template (Mustache).

  Variables: `has_retries` (bool), `retry_count` (int).
  """
  @spec must_return_warning() :: String.t()
  def must_return_warning, do: @must_return_warning

  @doc """
  Retry phase feedback template (Mustache).

  Variables: `is_final_retry`, `current_retry`, `total_retries`,
  `retries_remaining`, `next_turn`.
  """
  @spec retry_feedback() :: String.t()
  def retry_feedback, do: @retry_feedback

  # ============================================================================
  # MetaPlanner Templates
  # ============================================================================

  @planning_examples_file Path.join(@prompts_dir, "planning-examples.md")
  @verification_guide_file Path.join(@prompts_dir, "verification-predicate-guide.md")
  @verification_reminder_file Path.join(@prompts_dir, "verification-predicate-reminder.md")
  @signature_guide_file Path.join(@prompts_dir, "signature-guide.md")

  @external_resource @planning_examples_file
  @external_resource @verification_guide_file
  @external_resource @verification_reminder_file
  @external_resource @signature_guide_file

  @planning_examples @planning_examples_file |> File.read!() |> PromptLoader.extract_content()
  @verification_guide @verification_guide_file |> File.read!() |> PromptLoader.extract_content()
  @verification_reminder @verification_reminder_file
                         |> File.read!()
                         |> PromptLoader.extract_content()
  @signature_guide @signature_guide_file |> File.read!() |> PromptLoader.extract_content()

  @doc "Example plan structure for MetaPlanner."
  @spec planning_examples() :: String.t()
  def planning_examples, do: @planning_examples

  @doc "Comprehensive guide for writing verification predicates."
  @spec verification_guide() :: String.t()
  def verification_guide, do: @verification_guide

  @doc "Quick reference reminder for verification predicates."
  @spec verification_reminder() :: String.t()
  def verification_reminder, do: @verification_reminder

  @doc "Guide for writing task signatures."
  @spec signature_guide() :: String.t()
  def signature_guide, do: @signature_guide

  # ============================================================================
  # Utility
  # ============================================================================

  @doc """
  List all available prompt keys.

  ## Examples

      iex> keys = PtcRunner.Prompts.list()
      iex> :reference in keys
      true

  """
  @spec list() :: [atom()]
  def list do
    [
      :reference,
      :behavior_single_shot,
      :behavior_multi_turn,
      :behavior_return_explicit,
      :behavior_return_auto,
      :capability_journal,
      :repl,
      :json_system,
      :json_user,
      :json_error,
      :tool_calling_system,
      :must_return_warning,
      :retry_feedback,
      :planning_examples,
      :verification_guide,
      :verification_reminder,
      :signature_guide
    ]
  end

  @doc """
  Get a prompt by key.

  ## Examples

      iex> prompt = PtcRunner.Prompts.get(:reference)
      iex> String.contains?(prompt, "<role>")
      true

      iex> PtcRunner.Prompts.get(:unknown)
      nil

  """
  @spec get(atom()) :: String.t() | nil
  def get(:reference), do: reference()
  def get(:behavior_single_shot), do: behavior_single_shot()
  def get(:behavior_multi_turn), do: behavior_multi_turn()
  def get(:behavior_return_explicit), do: behavior_return_explicit()
  def get(:behavior_return_auto), do: behavior_return_auto()
  def get(:capability_journal), do: capability_journal()
  def get(:repl), do: repl()
  def get(:json_system), do: json_system()
  def get(:json_user), do: json_user()
  def get(:json_error), do: json_error()
  def get(:tool_calling_system), do: tool_calling_system()
  def get(:must_return_warning), do: must_return_warning()
  def get(:retry_feedback), do: retry_feedback()
  def get(:planning_examples), do: planning_examples()
  def get(:verification_guide), do: verification_guide()
  def get(:verification_reminder), do: verification_reminder()
  def get(:signature_guide), do: signature_guide()
  def get(_), do: nil
end
