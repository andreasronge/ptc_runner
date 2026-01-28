defmodule PtcRunner.SubAgent.LLMTool do
  @moduledoc """
  LLM-powered tools for classification, evaluation, and judgment.

  LLMTool allows you to create tools that use an LLM to make decisions or
  generate structured outputs. The tool is configured with a prompt template
  and signature that defines its inputs and outputs.

  ## Use Cases

  LLMTool is ideal for:
  - **Classification** - Categorize inputs (sentiment, priority, type)
  - **Evaluation** - Score quality, relevance, urgency
  - **Judgment** - Make yes/no decisions with reasoning
  - **Extraction** - Pull structured data from text

  For complex multi-step tasks, use `SubAgent.as_tool/2` instead.

  ## LLM Inheritance

  The `:llm` option controls which LLM is used:

  | Value | Behavior |
  |-------|----------|
  | `:caller` (default) | Inherit from calling agent |
  | `:haiku`, `:sonnet` | Specific model via registry |
  | `fn input -> result end` | Custom LLM function |

  The `:caller` atom is only valid for LLMTool and explicitly signals
  "use whatever LLM the calling agent is using."

  ## Execution

  ## Three Output Modes

  1. **JSON mode** (default) — LLM returns JSON, validated against signature return type.
  2. **Template mode** — LLM returns JSON (`json_signature`), then `response_template`
     renders a PTC-Lisp expression with Mustache placeholders filled from the JSON.
     The template runs in a no-tools sandbox. Best for turning simple LLM judgments
     (booleans, numbers) into typed Lisp values (keywords, expressions).

  Template mode fields:
  - `:json_signature` — Signature for the internal JSON call (falls back to `:signature`)
  - `:response_template` — PTC-Lisp string with `{{placeholder}}` references to JSON fields

  **Safety note:** `response_template` injects raw JSON values into PTC-Lisp source.
  This is safe for structural primitives (booleans, keywords, numbers). Avoid string
  interpolation where quotes could break Lisp parsing.

  ## Examples

      iex> PtcRunner.SubAgent.LLMTool.new(
      ...>   prompt: "Is {{email}} urgent for {{tier}} customer?",
      ...>   signature: "(email :string, tier :string) -> {urgent :bool, reason :string}"
      ...> )
      %PtcRunner.SubAgent.LLMTool{
        prompt: "Is {{email}} urgent for {{tier}} customer?",
        signature: "(email :string, tier :string) -> {urgent :bool, reason :string}",
        llm: :caller,
        description: nil,
        tools: nil,
        response_template: nil,
        json_signature: nil
      }

      iex> PtcRunner.SubAgent.LLMTool.new(
      ...>   prompt: "Classify {{text}}",
      ...>   signature: "(text :string) -> {category :string}",
      ...>   llm: :haiku,
      ...>   description: "Classifies text into categories"
      ...> )
      %PtcRunner.SubAgent.LLMTool{
        prompt: "Classify {{text}}",
        signature: "(text :string) -> {category :string}",
        llm: :haiku,
        description: "Classifies text into categories",
        tools: nil,
        response_template: nil,
        json_signature: nil
      }

  """

  defstruct [:prompt, :signature, :llm, :description, :tools, :response_template, :json_signature]

  @type t :: %__MODULE__{
          prompt: String.t(),
          signature: String.t(),
          llm: :caller | atom() | function() | nil,
          description: String.t() | nil,
          tools: map() | nil,
          response_template: String.t() | nil,
          json_signature: String.t() | nil
        }

  @doc """
  Create a new LLMTool with validation.

  ## Options

  - `:prompt` (required) - Template with `{{placeholder}}` references
  - `:signature` (required) - Contract (inputs validated against placeholders)
  - `:llm` - `:caller` (default), atom (registry lookup), or function
  - `:description` - For schema generation
  - `:tools` - If provided, runs as multi-turn agent
  - `:response_template` - PTC-Lisp template with `{{placeholder}}` for JSON fields
  - `:json_signature` - Signature for the internal JSON call (falls back to `:signature`)

  ## Examples

      iex> PtcRunner.SubAgent.LLMTool.new(prompt: "Hello {{name}}", signature: "(name :string) -> :string")
      %PtcRunner.SubAgent.LLMTool{prompt: "Hello {{name}}", signature: "(name :string) -> :string", llm: :caller, description: nil, tools: nil, response_template: nil, json_signature: nil}

      iex> PtcRunner.SubAgent.LLMTool.new(prompt: "Hi", signature: ":string")
      %PtcRunner.SubAgent.LLMTool{prompt: "Hi", signature: ":string", llm: :caller, description: nil, tools: nil, response_template: nil, json_signature: nil}

  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    validate_required_fields!(opts)
    validate_types!(opts)
    validate_prompt_placeholders!(opts)

    # Set default llm to :caller
    opts = Keyword.put_new(opts, :llm, :caller)

    struct(__MODULE__, opts)
  end

  # Validate that required fields are present
  defp validate_required_fields!(opts) do
    case Keyword.fetch(opts, :prompt) do
      {:ok, _} -> :ok
      :error -> raise ArgumentError, "prompt is required"
    end

    case Keyword.fetch(opts, :signature) do
      {:ok, _} -> :ok
      :error -> raise ArgumentError, "signature is required"
    end
  end

  # Validate types of provided fields
  defp validate_types!(opts) do
    validate_prompt!(opts)
    validate_signature!(opts)
    validate_llm!(opts)
    validate_description!(opts)
    validate_tools!(opts)
    validate_response_template!(opts)
    validate_json_signature!(opts)
  end

  defp validate_prompt!(opts) do
    case Keyword.fetch(opts, :prompt) do
      {:ok, prompt} when is_binary(prompt) and byte_size(prompt) > 0 -> :ok
      {:ok, ""} -> raise ArgumentError, "prompt cannot be empty"
      {:ok, _} -> raise ArgumentError, "prompt must be a string"
      :error -> :ok
    end
  end

  defp validate_signature!(opts) do
    case Keyword.fetch(opts, :signature) do
      {:ok, sig} when is_binary(sig) -> :ok
      {:ok, _} -> raise ArgumentError, "signature must be a string"
      :error -> :ok
    end
  end

  defp validate_llm!(opts) do
    case Keyword.fetch(opts, :llm) do
      {:ok, :caller} -> :ok
      {:ok, llm} when is_atom(llm) -> :ok
      {:ok, llm} when is_function(llm) -> :ok
      {:ok, nil} -> :ok
      {:ok, _} -> raise ArgumentError, "llm must be :caller, an atom, a function, or nil"
      :error -> :ok
    end
  end

  defp validate_description!(opts) do
    case Keyword.fetch(opts, :description) do
      {:ok, desc} when is_binary(desc) -> :ok
      {:ok, nil} -> :ok
      {:ok, _} -> raise ArgumentError, "description must be a string or nil"
      :error -> :ok
    end
  end

  defp validate_tools!(opts) do
    case Keyword.fetch(opts, :tools) do
      {:ok, tools} when is_map(tools) -> :ok
      {:ok, nil} -> :ok
      {:ok, _} -> raise ArgumentError, "tools must be a map or nil"
      :error -> :ok
    end
  end

  defp validate_response_template!(opts) do
    case Keyword.fetch(opts, :response_template) do
      {:ok, t} when is_binary(t) -> :ok
      {:ok, nil} -> :ok
      {:ok, _} -> raise ArgumentError, "response_template must be a string or nil"
      :error -> :ok
    end
  end

  defp validate_json_signature!(opts) do
    case Keyword.fetch(opts, :json_signature) do
      {:ok, s} when is_binary(s) -> :ok
      {:ok, nil} -> :ok
      {:ok, _} -> raise ArgumentError, "json_signature must be a string or nil"
      :error -> :ok
    end
  end

  # Validate that prompt placeholders match signature parameters
  defp validate_prompt_placeholders!(opts) do
    alias PtcRunner.SubAgent.PromptExpander

    with {:ok, prompt} <- Keyword.fetch(opts, :prompt),
         {:ok, signature} <- Keyword.fetch(opts, :signature) do
      placeholders = PromptExpander.extract_placeholder_names(prompt)
      signature_params = PromptExpander.extract_signature_params(signature)

      case placeholders -- signature_params do
        [] ->
          :ok

        missing ->
          formatted_missing = Enum.map_join(missing, ", ", &"{{#{&1}}}")

          raise ArgumentError,
                "placeholders #{formatted_missing} not found in signature"
      end
    else
      _ -> :ok
    end
  end
end
