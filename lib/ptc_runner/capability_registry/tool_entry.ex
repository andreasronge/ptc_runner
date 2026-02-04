defmodule PtcRunner.CapabilityRegistry.ToolEntry do
  @moduledoc """
  Tool metadata for the Capability Registry.

  Represents both base tools (Elixir functions) and composed tools (PTC-Lisp code).
  Tracks success rates, context affinity, and usage statistics for intelligent
  tool selection.

  ## Layers

  - `:base` - Developer-provided Elixir functions (primitives)
  - `:composed` - PTC-Lisp code combining other tools (smithed)

  ## Sources

  - `:developer` - Manually registered by developers
  - `:smithed` - Automatically created through tool smithing

  ## Example

      %ToolEntry{
        id: "parse_csv_eu",
        capability_id: "parse_csv",
        name: "European CSV Parser",
        description: "Parse CSV with European format support",
        signature: "(text :string) -> [{:map}]",
        layer: :composed,
        source: :developer,
        tags: ["csv", "parsing", "european"],
        code: "(defn parse-csv-eu [text] ...)",
        success_rate: 0.94,
        context_success: %{"european" => 0.98, "csv" => 0.91}
      }

  """

  @type t :: %__MODULE__{
          id: String.t(),
          capability_id: String.t() | nil,
          name: String.t(),
          description: String.t() | nil,
          signature: String.t() | nil,
          layer: :base | :composed,
          source: :developer | :smithed,
          tags: [String.t()],
          code: String.t() | nil,
          function: (map() -> term()) | nil,
          dependencies: [String.t()],
          examples: [example()],
          success_rate: float(),
          context_success: %{String.t() => float()},
          supersedes: String.t() | nil,
          version: pos_integer(),
          created_at: DateTime.t(),
          last_linked_at: DateTime.t() | nil,
          link_count: non_neg_integer()
        }

  @type example :: %{input: map(), output: term()}

  defstruct [
    :id,
    :capability_id,
    :name,
    :description,
    :signature,
    :layer,
    :source,
    :code,
    :function,
    :supersedes,
    :created_at,
    :last_linked_at,
    tags: [],
    dependencies: [],
    examples: [],
    success_rate: 1.0,
    context_success: %{},
    version: 1,
    link_count: 0
  ]

  @doc """
  Creates a new base tool entry from an Elixir function.

  ## Examples

      iex> entry = PtcRunner.CapabilityRegistry.ToolEntry.new_base(
      ...>   "search",
      ...>   fn args -> [] end,
      ...>   signature: "(query :string) -> [{title :string}]",
      ...>   description: "Search for items",
      ...>   tags: ["search", "query"]
      ...> )
      iex> entry.id
      "search"
      iex> entry.layer
      :base

  """
  @spec new_base(String.t(), (map() -> term()), keyword()) :: t()
  def new_base(id, function, opts \\ []) when is_binary(id) and is_function(function) do
    %__MODULE__{
      id: id,
      capability_id: Keyword.get(opts, :capability_id),
      name: Keyword.get(opts, :name, id),
      description: Keyword.get(opts, :description),
      signature: Keyword.get(opts, :signature),
      layer: :base,
      source: :developer,
      tags: Keyword.get(opts, :tags, []),
      function: function,
      code: nil,
      dependencies: [],
      supersedes: Keyword.get(opts, :supersedes),
      examples: Keyword.get(opts, :examples, []),
      success_rate: 1.0,
      context_success: %{},
      version: 1,
      created_at: DateTime.utc_now(),
      last_linked_at: nil,
      link_count: 0
    }
  end

  @doc """
  Creates a new composed tool entry from PTC-Lisp code.

  ## Examples

      iex> entry = PtcRunner.CapabilityRegistry.ToolEntry.new_composed(
      ...>   "extract_data",
      ...>   "(defn extract-data [path] (-> (tool/file-read {:path path}) (parse-csv)))",
      ...>   signature: "(path :string) -> [{:map}]",
      ...>   dependencies: ["file-read", "parse-csv"]
      ...> )
      iex> entry.layer
      :composed

  """
  @spec new_composed(String.t(), String.t(), keyword()) :: t()
  def new_composed(id, code, opts \\ []) when is_binary(id) and is_binary(code) do
    %__MODULE__{
      id: id,
      capability_id: Keyword.get(opts, :capability_id),
      name: Keyword.get(opts, :name, id),
      description: Keyword.get(opts, :description),
      signature: Keyword.get(opts, :signature),
      layer: :composed,
      source: Keyword.get(opts, :source, :developer),
      tags: Keyword.get(opts, :tags, []),
      function: nil,
      code: code,
      dependencies: Keyword.get(opts, :dependencies, []),
      examples: Keyword.get(opts, :examples, []),
      success_rate: 1.0,
      context_success: %{},
      supersedes: Keyword.get(opts, :supersedes),
      version: Keyword.get(opts, :version, 1),
      created_at: DateTime.utc_now(),
      last_linked_at: nil,
      link_count: 0
    }
  end

  @doc """
  Records a link event, updating statistics.
  """
  @spec record_link(t()) :: t()
  def record_link(entry) do
    %{entry | last_linked_at: DateTime.utc_now(), link_count: entry.link_count + 1}
  end

  @doc """
  Updates success rate with a new trial outcome.

  Uses exponential moving average with alpha = 0.1 for stability.
  """
  @spec update_success_rate(t(), boolean()) :: t()
  def update_success_rate(entry, success?) do
    alpha = 0.1
    outcome = if success?, do: 1.0, else: 0.0
    new_rate = alpha * outcome + (1 - alpha) * entry.success_rate
    %{entry | success_rate: new_rate}
  end

  @doc """
  Updates context-specific success rate.
  """
  @spec update_context_success(t(), String.t(), boolean()) :: t()
  def update_context_success(entry, context_tag, success?) do
    alpha = 0.1
    outcome = if success?, do: 1.0, else: 0.0
    current = Map.get(entry.context_success, context_tag, 1.0)
    new_rate = alpha * outcome + (1 - alpha) * current
    %{entry | context_success: Map.put(entry.context_success, context_tag, new_rate)}
  end

  @doc """
  Converts to a JSON-serializable map.

  Base tool functions are stored as references since they can't be serialized.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = entry) do
    base = Map.from_struct(entry)

    base
    |> Map.put(:function, serialize_function(entry))
    |> Map.put(:created_at, DateTime.to_iso8601(entry.created_at))
    |> Map.put(:layer, Atom.to_string(entry.layer))
    |> Map.put(:source, Atom.to_string(entry.source))
    |> Map.update(:last_linked_at, nil, fn
      nil -> nil
      dt -> DateTime.to_iso8601(dt)
    end)
  end

  defp serialize_function(%{layer: :base, id: id}), do: ["base_ref", id]
  defp serialize_function(_), do: nil

  @doc """
  Creates from a JSON map.

  Requires a function resolver for base tools.
  """
  @spec from_json(map(), (String.t() -> (map() -> term()) | nil)) :: {:ok, t()} | {:error, term()}
  def from_json(data, function_resolver \\ fn _ -> nil end) do
    {:ok, created_at, _} = DateTime.from_iso8601(data["created_at"])

    last_linked_at =
      case data["last_linked_at"] do
        nil -> nil
        iso -> elem(DateTime.from_iso8601(iso), 1)
      end

    function =
      case data["function"] do
        ["base_ref", id] -> function_resolver.(id)
        {:base_ref, id} -> function_resolver.(id)
        _ -> nil
      end

    {:ok,
     %__MODULE__{
       id: data["id"],
       capability_id: data["capability_id"],
       name: data["name"],
       description: data["description"],
       signature: data["signature"],
       layer: String.to_existing_atom(data["layer"]),
       source: String.to_existing_atom(data["source"]),
       tags: data["tags"] || [],
       code: data["code"],
       function: function,
       dependencies: data["dependencies"] || [],
       examples: data["examples"] || [],
       success_rate: data["success_rate"] || 1.0,
       context_success: data["context_success"] || %{},
       supersedes: data["supersedes"],
       version: data["version"] || 1,
       created_at: created_at,
       last_linked_at: last_linked_at,
       link_count: data["link_count"] || 0
     }}
  rescue
    e -> {:error, {:deserialization_failed, e}}
  end
end
