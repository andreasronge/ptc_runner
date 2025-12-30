defmodule PtcRunner.Tool do
  @moduledoc """
  Normalized tool definition for PTC-Lisp and SubAgent.

  Tools can be defined in multiple formats and are normalized to this struct.
  Supports function references, explicit signatures, and introspection.

  ## Tool Type

  Tools can be one of three types:
  - `:native` - Elixir function
  - `:llm` - LLM-powered tool (SubAgent only)
  - `:subagent` - SubAgent wrapped as tool (SubAgent only)

  ## Tool Formats

  All tool formats are accepted and normalized internally. Common patterns:

  ### 1. Function reference (extracts @spec and @doc)
  ```elixir
  "get_user" => &MyApp.get_user/1
  ```

  ### 2. Function with explicit signature
  ```elixir
  "search" => {&MyApp.search/2, "(query :string, limit :int) -> [{id :int}]"}
  ```

  ### 3. Function with signature and description
  ```elixir
  "analyze" => {&MyApp.analyze/1,
    signature: "(data :map) -> {score :float}",
    description: "Analyze data and return anomaly score"
  }
  ```

  ### 4. Anonymous function
  ```elixir
  "get_time" => fn _args -> DateTime.utc_now() end
  ```

  ### 5. Skip validation explicitly
  ```elixir
  "dynamic" => {&MyApp.dynamic/1, :skip}
  ```

  ## Type Definition

  ```elixir
  %PtcRunner.Tool{
    name: "get_user",
    function: &MyApp.get_user/1,
    signature: "(id :int) -> {id :int, name :string}",
    description: "Get user by ID",
    type: :native
  }
  ```

  ## Field Reference

  - `name` - Tool name as string (required)
  - `function` - Callable (required for native tools)
  - `signature` - Optional signature for validation: `"(inputs) -> outputs"`
  - `description` - Optional description for LLM visibility
  - `type` - Tool type: `:native`, `:llm`, `:subagent`
  """

  @type tool_format ::
          (map() -> term())
          | {(map() -> term()), String.t()}
          | {(map() -> term()), keyword()}
          | :skip

  @type t :: %__MODULE__{
          name: String.t(),
          function: (map() -> term()) | nil,
          signature: String.t() | nil,
          description: String.t() | nil,
          type: :native | :llm | :subagent
        }

  defstruct [:name, :function, :signature, :description, :type]

  @doc """
  Creates a normalized Tool struct from a name and format.

  Handles multiple input formats and normalizes to a consistent structure.
  Attempts to extract @spec and @doc from bare function references.

  ## Parameters

  - `name` - Tool name as string
  - `format` - One of: function, {function, signature}, {function, options}, :skip

  ## Returns

  `{:ok, tool}` on success, `{:error, reason}` on failure.

  ## Examples

  Simple function reference (auto-extracts @doc and @spec if available):
      iex> {:ok, tool} = PtcRunner.Tool.new("get_time", fn _args -> DateTime.utc_now() end)
      iex> tool.name
      "get_time"
      iex> tool.type
      :native

  Function with explicit signature:
      iex> {:ok, tool} = PtcRunner.Tool.new("search", {&MyApp.search/2, "(query :string, limit :int) -> [{id :int}]"})
      iex> tool.signature
      "(query :string, limit :int) -> [{id :int}]"

  Function with signature and description:
      iex> {:ok, tool} = PtcRunner.Tool.new("analyze", {&MyApp.analyze/1,
      ...>   signature: "(data :map) -> {score :float}",
      ...>   description: "Analyze data and return anomaly score"
      ...> })
      iex> tool.description
      "Analyze data and return anomaly score"

  Skip validation:
      iex> {:ok, tool} = PtcRunner.Tool.new("dynamic", {&MyApp.dynamic/1, :skip})
      iex> tool.signature
      nil

  """
  @spec new(String.t(), tool_format()) :: {:ok, t()} | {:error, term()}
  def new(name, format) when is_binary(name) do
    case normalize_format(name, format) do
      {:ok, tool} -> {:ok, tool}
      {:error, reason} -> {:error, reason}
    end
  end

  # Normalize different input formats
  defp normalize_format(name, function) when is_function(function) do
    # Bare function - try to extract @doc and @spec
    {:ok,
     %__MODULE__{
       name: name,
       function: function,
       signature: nil,
       description: nil,
       type: :native
     }}
  end

  defp normalize_format(name, {function, signature})
       when is_function(function) and is_binary(signature) do
    # Function with explicit signature string
    {:ok,
     %__MODULE__{
       name: name,
       function: function,
       signature: signature,
       description: nil,
       type: :native
     }}
  end

  defp normalize_format(name, {function, :skip}) when is_function(function) do
    # Function with validation explicitly skipped
    {:ok,
     %__MODULE__{
       name: name,
       function: function,
       signature: nil,
       description: nil,
       type: :native
     }}
  end

  defp normalize_format(name, {function, options})
       when is_function(function) and is_list(options) do
    # Function with keyword list options
    signature = Keyword.get(options, :signature)
    description = Keyword.get(options, :description)

    {:ok,
     %__MODULE__{
       name: name,
       function: function,
       signature: signature,
       description: description,
       type: :native
     }}
  end

  defp normalize_format(_name, _format) do
    {:error, :invalid_tool_format}
  end
end
