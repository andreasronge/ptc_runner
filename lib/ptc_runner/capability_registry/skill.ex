defmodule PtcRunner.CapabilityRegistry.Skill do
  @moduledoc """
  Reusable expertise captured as a prompt fragment.

  Unlike tools, skills don't execute - they guide agent reasoning by being
  injected into the system prompt. Skills are cheap to create and test
  compared to tools.

  ## Linking

  Skills are linked to agents at resolution time through two mechanisms:

  1. **`applies_to`** - List of tool IDs this skill enhances
  2. **Context tags** - Matched against mission context

  ## Model Sensitivity

  Skills (prompts) are more sensitive to the underlying model than tools (code).
  The `model_success` field tracks effectiveness per model.

  ## Example

      %Skill{
        id: "european_csv_handling",
        name: "European CSV Handling",
        prompt: \"\"\"
        When working with European CSV files:
        - Use semicolon (;) as the default delimiter
        - Dates are formatted as DD/MM/YYYY
        - Numbers use comma for decimals: 1.234,56
        \"\"\",
        applies_to: ["parse_csv", "validate_csv"],
        tags: ["csv", "european", "i18n"],
        model_success: %{
          "claude-sonnet-4" => 0.96,
          "claude-haiku" => 0.82
        }
      }

  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          prompt: String.t(),
          applies_to: [String.t()],
          tags: [String.t()],
          source: :developer | :learned,
          success_rate: float(),
          context_success: %{String.t() => float()},
          model_success: %{String.t() => float()},
          version: pos_integer(),
          created_at: DateTime.t(),
          last_linked_at: DateTime.t() | nil,
          link_count: non_neg_integer(),
          review_status: nil | :flagged_for_review | :under_review
        }

  defstruct [
    :id,
    :name,
    :description,
    :prompt,
    :created_at,
    :last_linked_at,
    applies_to: [],
    tags: [],
    source: :developer,
    success_rate: 1.0,
    context_success: %{},
    model_success: %{},
    version: 1,
    link_count: 0,
    review_status: nil
  ]

  @doc """
  Creates a new skill.

  ## Examples

      iex> skill = PtcRunner.CapabilityRegistry.Skill.new(
      ...>   "csv_tips",
      ...>   "CSV Handling Tips",
      ...>   "When parsing CSV files, check for BOM markers...",
      ...>   applies_to: ["parse_csv"],
      ...>   tags: ["csv", "parsing"]
      ...> )
      iex> skill.id
      "csv_tips"
      iex> skill.source
      :developer

  """
  @spec new(String.t(), String.t(), String.t(), keyword()) :: t()
  def new(id, name, prompt, opts \\ [])
      when is_binary(id) and is_binary(name) and is_binary(prompt) do
    %__MODULE__{
      id: id,
      name: name,
      description: Keyword.get(opts, :description),
      prompt: prompt,
      applies_to: Keyword.get(opts, :applies_to, []),
      tags: Keyword.get(opts, :tags, []),
      source: Keyword.get(opts, :source, :developer),
      success_rate: 1.0,
      context_success: %{},
      model_success: %{},
      version: Keyword.get(opts, :version, 1),
      created_at: DateTime.utc_now(),
      last_linked_at: nil,
      link_count: 0,
      review_status: nil
    }
  end

  @doc """
  Records a link event, updating statistics.
  """
  @spec record_link(t()) :: t()
  def record_link(skill) do
    %{skill | last_linked_at: DateTime.utc_now(), link_count: skill.link_count + 1}
  end

  @doc """
  Updates success rate with a new trial outcome.
  """
  @spec update_success_rate(t(), boolean()) :: t()
  def update_success_rate(skill, success?) do
    alpha = 0.1
    outcome = if success?, do: 1.0, else: 0.0
    new_rate = alpha * outcome + (1 - alpha) * skill.success_rate
    %{skill | success_rate: new_rate}
  end

  @doc """
  Updates model-specific success rate.
  """
  @spec update_model_success(t(), String.t(), boolean()) :: t()
  def update_model_success(skill, model_id, success?) do
    alpha = 0.1
    outcome = if success?, do: 1.0, else: 0.0
    current = Map.get(skill.model_success, model_id, 1.0)
    new_rate = alpha * outcome + (1 - alpha) * current
    %{skill | model_success: Map.put(skill.model_success, model_id, new_rate)}
  end

  @doc """
  Updates context-specific success rate.
  """
  @spec update_context_success(t(), String.t(), boolean()) :: t()
  def update_context_success(skill, context_tag, success?) do
    alpha = 0.1
    outcome = if success?, do: 1.0, else: 0.0
    current = Map.get(skill.context_success, context_tag, 1.0)
    new_rate = alpha * outcome + (1 - alpha) * current
    %{skill | context_success: Map.put(skill.context_success, context_tag, new_rate)}
  end

  @doc """
  Flags the skill for review (e.g., when a linked tool is repaired).
  """
  @spec flag_for_review(t(), String.t()) :: t()
  def flag_for_review(skill, _reason) do
    %{skill | review_status: :flagged_for_review}
  end

  @doc """
  Clears the review status.
  """
  @spec clear_review(t()) :: t()
  def clear_review(skill) do
    %{skill | review_status: nil}
  end

  @doc """
  Checks if a skill applies to any of the given tool IDs.
  """
  @spec applies_to_any?(t(), [String.t()]) :: boolean()
  def applies_to_any?(skill, tool_ids) do
    Enum.any?(skill.applies_to, &(&1 in tool_ids))
  end

  @doc """
  Gets the effectiveness score for a specific model.

  Returns overall success rate if no model-specific data.
  """
  @spec effectiveness_for_model(t(), String.t() | nil) :: float()
  def effectiveness_for_model(skill, nil), do: skill.success_rate

  def effectiveness_for_model(skill, model_id) do
    Map.get(skill.model_success, model_id, skill.success_rate)
  end

  @doc """
  Converts to a JSON-serializable map.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = skill) do
    skill
    |> Map.from_struct()
    |> Map.put(:created_at, DateTime.to_iso8601(skill.created_at))
    |> Map.put(:source, Atom.to_string(skill.source))
    |> Map.update(:last_linked_at, nil, fn
      nil -> nil
      dt -> DateTime.to_iso8601(dt)
    end)
    |> Map.update(:review_status, nil, fn
      nil -> nil
      status -> Atom.to_string(status)
    end)
  end

  @doc """
  Creates from a JSON map.
  """
  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(data) do
    {:ok, created_at, _} = DateTime.from_iso8601(data["created_at"])

    last_linked_at =
      case data["last_linked_at"] do
        nil -> nil
        iso -> elem(DateTime.from_iso8601(iso), 1)
      end

    review_status =
      case data["review_status"] do
        nil -> nil
        status when is_binary(status) -> String.to_existing_atom(status)
        status when is_atom(status) -> status
      end

    {:ok,
     %__MODULE__{
       id: data["id"],
       name: data["name"],
       description: data["description"],
       prompt: data["prompt"],
       applies_to: data["applies_to"] || [],
       tags: data["tags"] || [],
       source: String.to_existing_atom(data["source"]),
       success_rate: data["success_rate"] || 1.0,
       context_success: data["context_success"] || %{},
       model_success: data["model_success"] || %{},
       version: data["version"] || 1,
       created_at: created_at,
       last_linked_at: last_linked_at,
       link_count: data["link_count"] || 0,
       review_status: review_status
     }}
  rescue
    e -> {:error, {:deserialization_failed, e}}
  end
end
