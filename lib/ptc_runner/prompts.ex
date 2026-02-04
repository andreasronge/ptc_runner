defmodule PtcRunner.Prompts do
  @moduledoc """
  Centralized prompt loading for PtcRunner.

  All prompt templates are loaded from `priv/prompts/` at compile time and
  exposed through this module. Changes to prompt files trigger recompilation.

  ## Prompt Files

  | File | Function | Used By |
  |------|----------|---------|
  | `lisp-base.md` | `lisp_base/0` | `LanguageSpec` |
  | `lisp-addon-single_shot.md` | `lisp_addon_single_shot/0` | `LanguageSpec` |
  | `lisp-addon-multi_turn.md` | `lisp_addon_multi_turn/0` | `LanguageSpec` |
  | `json-system.md` | `json_system/0` | `JsonMode` |
  | `json-user.md` | `json_user/0` | `JsonMode` |
  | `json-error.md` | `json_error/0` | `JsonMode` |
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
  # PTC-Lisp Language Specs
  # ============================================================================

  @lisp_base_file Path.join(@prompts_dir, "lisp-base.md")
  @lisp_addon_single_shot_file Path.join(@prompts_dir, "lisp-addon-single_shot.md")
  @lisp_addon_multi_turn_file Path.join(@prompts_dir, "lisp-addon-multi_turn.md")

  @external_resource @lisp_base_file
  @external_resource @lisp_addon_single_shot_file
  @external_resource @lisp_addon_multi_turn_file

  @lisp_base @lisp_base_file |> File.read!() |> PromptLoader.extract_with_header()
  @lisp_addon_single_shot @lisp_addon_single_shot_file
                          |> File.read!()
                          |> PromptLoader.extract_with_header()
  @lisp_addon_multi_turn @lisp_addon_multi_turn_file
                         |> File.read!()
                         |> PromptLoader.extract_with_header()

  @doc "Core PTC-Lisp language reference (always included)."
  @spec lisp_base() :: String.t()
  def lisp_base, do: elem(@lisp_base, 1)

  @doc "Single-shot mode addon (no memory, no return/fail)."
  @spec lisp_addon_single_shot() :: String.t()
  def lisp_addon_single_shot, do: elem(@lisp_addon_single_shot, 1)

  @doc "Multi-turn mode addon (memory, return/fail, println)."
  @spec lisp_addon_multi_turn() :: String.t()
  def lisp_addon_multi_turn, do: elem(@lisp_addon_multi_turn, 1)

  @doc "Raw header + content for lisp-base.md (for metadata parsing)."
  @spec lisp_base_with_header() :: {String.t(), String.t()}
  def lisp_base_with_header, do: @lisp_base

  @doc "Raw header + content for lisp-addon-single_shot.md."
  @spec lisp_addon_single_shot_with_header() :: {String.t(), String.t()}
  def lisp_addon_single_shot_with_header, do: @lisp_addon_single_shot

  @doc "Raw header + content for lisp-addon-multi_turn.md."
  @spec lisp_addon_multi_turn_with_header() :: {String.t(), String.t()}
  def lisp_addon_multi_turn_with_header, do: @lisp_addon_multi_turn

  # ============================================================================
  # JSON Mode Templates
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

  @doc "JSON mode system prompt."
  @spec json_system() :: String.t()
  def json_system, do: @json_system

  @doc "JSON mode user message template (Mustache)."
  @spec json_user() :: String.t()
  def json_user, do: @json_user

  @doc "JSON mode error feedback template (Mustache)."
  @spec json_error() :: String.t()
  def json_error, do: @json_error

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
      iex> :lisp_base in keys
      true

  """
  @spec list() :: [atom()]
  def list do
    [
      :lisp_base,
      :lisp_addon_single_shot,
      :lisp_addon_multi_turn,
      :json_system,
      :json_user,
      :json_error,
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

      iex> prompt = PtcRunner.Prompts.get(:lisp_base)
      iex> String.contains?(prompt, "PTC-Lisp")
      true

      iex> PtcRunner.Prompts.get(:unknown)
      nil

  """
  @spec get(atom()) :: String.t() | nil
  def get(:lisp_base), do: lisp_base()
  def get(:lisp_addon_single_shot), do: lisp_addon_single_shot()
  def get(:lisp_addon_multi_turn), do: lisp_addon_multi_turn()
  def get(:json_system), do: json_system()
  def get(:json_user), do: json_user()
  def get(:json_error), do: json_error()
  def get(:must_return_warning), do: must_return_warning()
  def get(:retry_feedback), do: retry_feedback()
  def get(:planning_examples), do: planning_examples()
  def get(:verification_guide), do: verification_guide()
  def get(:verification_reminder), do: verification_reminder()
  def get(:signature_guide), do: signature_guide()
  def get(_), do: nil
end
