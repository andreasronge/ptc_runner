defmodule PtcRunner.Lisp.Tool do
  @moduledoc false

  alias PtcRunner.Lisp.TrustedTool
  alias PtcRunner.Lisp.TypeExtractor

  defstruct [
    :name,
    :function,
    :signature,
    :description,
    :type,
    :expose,
    :native_result,
    argument_collisions: :reject,
    visibility: :public,
    cache: false,
    ledger_arguments: :full
  ]

  @fields ~w(name function signature description type expose native_result visibility cache ledger_arguments)a

  @type t :: %__MODULE__{
          name: binary(),
          function: (map() -> term()) | nil,
          signature: binary() | nil,
          description: binary() | nil,
          type: atom() | nil,
          expose: atom() | nil,
          native_result: keyword() | nil,
          ledger_arguments: :full | (map() -> map()),
          argument_collisions: :reject | :pass,
          visibility: :public | :private,
          cache: boolean()
        }

  @spec new(binary(), term()) :: {:ok, t()} | {:error, term()}
  def new(name, %__MODULE__{} = tool) when is_binary(name),
    do: validate(%{tool | name: tool.name || name, argument_collisions: :reject})

  def new(name, %TrustedTool{function: function, ledger_arguments: ledger_arguments})
      when is_binary(name) and is_function(function, 1),
      do:
        validate(%__MODULE__{
          name: name,
          function: function,
          ledger_arguments: ledger_arguments,
          type: :native,
          argument_collisions: :pass
        })

  def new(name, %_{} = tool) when is_binary(name) do
    fields = Map.from_struct(tool)

    if Map.has_key?(fields, :function) do
      fields
      |> Map.take(@fields)
      |> Map.put(:name, Map.get(fields, :name) || name)
      |> then(&struct(__MODULE__, &1))
      |> validate()
    else
      {:error, :unsupported_tool}
    end
  end

  def new(name, function) when is_binary(name) and is_function(function) do
    {:ok, {signature, description}} = TypeExtractor.extract(function)

    validate(%__MODULE__{
      name: name,
      function: function,
      signature: signature,
      description: description,
      type: :native
    })
  end

  def new(name, {function, :skip}) when is_binary(name) and is_function(function),
    do: validate(%__MODULE__{name: name, function: function, type: :native})

  def new(name, {function, signature})
      when is_binary(name) and is_function(function) and is_binary(signature),
      do:
        validate(%__MODULE__{
          name: name,
          function: function,
          signature: signature,
          type: :native
        })

  def new(name, {function, options})
      when is_binary(name) and is_function(function) and is_list(options) do
    known = [:signature, :description, :cache, :visibility, :expose, :native_result]

    if Keyword.keyword?(options) and Keyword.keys(options) -- known == [] do
      validate(%__MODULE__{
        name: name,
        function: function,
        signature: Keyword.get(options, :signature),
        description: Keyword.get(options, :description),
        cache: Keyword.get(options, :cache, false),
        visibility: Keyword.get(options, :visibility, :public),
        expose: Keyword.get(options, :expose),
        native_result: Keyword.get(options, :native_result),
        type: :native
      })
    else
      {:error, :invalid_options}
    end
  end

  def new(_name, _format), do: {:error, :unsupported_tool}

  @spec private?(t()) :: boolean()
  def private?(%__MODULE__{visibility: :private}), do: true
  def private?(%__MODULE__{}), do: false

  defp validate(
         %__MODULE__{
           function: function,
           visibility: visibility,
           cache: cache,
           ledger_arguments: ledger_arguments,
           argument_collisions: collisions
         } = tool
       )
       when is_function(function) and visibility in [:public, :private] and is_boolean(cache) and
              collisions in [:reject, :pass] and
              (ledger_arguments == :full or is_function(ledger_arguments, 1)),
       do: {:ok, tool}

  defp validate(_tool), do: {:error, :invalid_tool}
end
