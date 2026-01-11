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

  LLMTool executes as a single-shot SubAgent when called:
  1. Arguments validated against signature parameters
  2. Template expanded with arguments
  3. LLM called for response
  4. Response parsed as PTC-Lisp, executed
  5. Result validated against signature return type

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
        tools: nil
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
        tools: nil
      }

  """

  defstruct [:prompt, :signature, :llm, :description, :tools]

  @type t :: %__MODULE__{
          prompt: String.t(),
          signature: String.t(),
          llm: :caller | atom() | function() | nil,
          description: String.t() | nil,
          tools: map() | nil
        }

  @doc """
  Create a new LLMTool with validation.

  ## Options

  - `:prompt` (required) - Template with `{{placeholder}}` references
  - `:signature` (required) - Contract (inputs validated against placeholders)
  - `:llm` - `:caller` (default), atom (registry lookup), or function
  - `:description` - For schema generation
  - `:tools` - If provided, runs as multi-turn agent

  ## Examples

      iex> PtcRunner.SubAgent.LLMTool.new(prompt: "Hello {{name}}", signature: "(name :string) -> :string")
      %PtcRunner.SubAgent.LLMTool{prompt: "Hello {{name}}", signature: "(name :string) -> :string", llm: :caller, description: nil, tools: nil}

      iex> PtcRunner.SubAgent.LLMTool.new(prompt: "Hi", signature: ":string")
      %PtcRunner.SubAgent.LLMTool{prompt: "Hi", signature: ":string", llm: :caller, description: nil, tools: nil}

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

  # Validate that prompt placeholders match signature parameters
  defp validate_prompt_placeholders!(opts) do
    alias PtcRunner.SubAgent.MissionExpander

    with {:ok, prompt} <- Keyword.fetch(opts, :prompt),
         {:ok, signature} <- Keyword.fetch(opts, :signature) do
      placeholders = MissionExpander.extract_placeholder_names(prompt)
      signature_params = MissionExpander.extract_signature_params(signature)

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
