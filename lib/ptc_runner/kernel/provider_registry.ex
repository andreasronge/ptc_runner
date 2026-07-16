defmodule PtcRunner.Kernel.ProviderRegistry do
  @moduledoc """
  Host-owned mapping from manifest provider names to trusted builders.

  A manifest can select a bounded provider name and JSON configuration; it
  cannot register a module, function, callback, command, or code URL. Builders
  receive the canonical manifest directory, requested workflow or mission
  destination, building owner, and installed limits. They return either one
  legacy `PtcRunner.Kernel.Capability` or a normalized provider build with one
  or more capabilities, an optional safe snapshot, and an optional idempotent
  close function.

  The built-ins are `llm`, permitted only in the workflow environment, and
  `file-read`, permitted only in the mission environment. Additional builders
  cannot replace built-in names. Builder exceptions are contained as
  `:provider_build_failed` during construction.
  """

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.FileCapability
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.LLMCapability

  @enforce_keys [:builders]
  defstruct [:builders]

  @type build_context :: %{
          directory: binary(),
          destination: :workflow | :mission,
          owner: pid(),
          limits: PtcRunner.Kernel.Limits.t(),
          installed_limits: PtcRunner.Kernel.Limits.t()
        }
  @type context :: %{
          directory: binary(),
          destination: :workflow | :mission,
          owner: pid(),
          limits: PtcRunner.Kernel.Limits.t(),
          installed_limits: PtcRunner.Kernel.Limits.t(),
          provider: binary()
        }
  @type built_provider :: %{
          capabilities: [Capability.t()],
          snapshot: map() | nil,
          close: (-> :ok) | nil
        }
  @type builder ::
          (map(), context() ->
             {:ok, Capability.t() | built_provider()} | {:error, term()})
  @type t :: %__MODULE__{builders: %{binary() => builder()}}

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_provider_registry}
  @doc """
  Creates a registry with the built-ins and optional additional builder
  functions keyed by provider name.
  """
  def new(additional_builders \\ %{})

  def new(additional_builders) when is_map(additional_builders) do
    builtins = %{"file-read" => &build_file/2, "llm" => &build_llm/2}

    if Enum.all?(additional_builders, fn {name, builder} ->
         valid_name?(name) and is_function(builder, 2) and not Map.has_key?(builtins, name)
       end) do
      {:ok, %__MODULE__{builders: Map.merge(builtins, additional_builders)}}
    else
      {:error, :invalid_provider_registry}
    end
  end

  def new(_builders), do: {:error, :invalid_provider_registry}

  @spec build(t(), binary(), map(), build_context()) ::
          {:ok, built_provider()} | {:error, term()}
  @doc "Builds and normalizes one trusted registry entry."
  def build(%__MODULE__{builders: builders}, name, config, context) do
    case Map.fetch(builders, name) do
      {:ok, builder} -> builder.(config, Map.put(context, :provider, name)) |> normalize_build()
      :error -> {:error, :unknown_provider}
    end
  rescue
    _exception -> {:error, :provider_build_failed}
  catch
    _kind, _reason -> {:error, :provider_build_failed}
  end

  defp normalize_build({:ok, %Capability{} = capability}) do
    {:ok, %{capabilities: [capability], snapshot: nil, close: nil}}
  end

  defp normalize_build({:ok, %{capabilities: capabilities} = built}) do
    snapshot = Map.get(built, :snapshot)
    close = Map.get(built, :close)

    if Map.keys(built) -- [:capabilities, :snapshot, :close] == [] and
         capabilities != [] and length(capabilities) <= 128 and
         Enum.all?(capabilities, &match?(%Capability{}, &1)) and
         (is_nil(snapshot) or JSONValue.map?(snapshot)) and
         (is_nil(close) or is_function(close, 0)) do
      {:ok, %{capabilities: capabilities, snapshot: snapshot, close: close}}
    else
      {:error, :invalid_provider_build}
    end
  end

  defp normalize_build({:error, _reason} = error), do: error
  defp normalize_build(_result), do: {:error, :invalid_provider_build}

  defp build_file(config, %{directory: directory, destination: :mission}) do
    with :ok <- exact_keys(config, ~w(root max_bytes), ~w(root)),
         root when is_binary(root) <- config["root"],
         {:ok, root} <- safe_directory(directory, root),
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <-
           Map.get(config, "max_bytes", 1_000_000) do
      FileCapability.new(root: root, max_bytes: max_bytes)
    else
      _ -> {:error, :invalid_file_provider}
    end
  end

  defp build_file(_config, _context), do: {:error, :provider_destination_denied}

  defp build_llm(config, %{destination: :workflow}) do
    with :ok <- exact_keys(config, ~w(model cache), ~w(model)),
         model when is_binary(model) and byte_size(model) in 1..256 <- config["model"],
         cache when is_boolean(cache) <- Map.get(config, "cache", false) do
      requester = PtcRunner.LLM.callback(model, cache: cache)
      LLMCapability.new(requester: fn request -> requester.(adapter_request(request)) end)
    else
      _ -> {:error, :invalid_llm_provider}
    end
  end

  defp build_llm(_config, _context), do: {:error, :provider_destination_denied}

  defp adapter_request(request) do
    request
    |> Map.take(~w(system messages tools cache))
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), adapter_value(key, value)} end)
  end

  defp adapter_value("messages", messages) when is_list(messages),
    do: Enum.map(messages, &adapter_message/1)

  defp adapter_value("tool_calls", calls) when is_list(calls),
    do: Enum.map(calls, &adapter_tool_call/1)

  defp adapter_value(_key, value), do: value

  defp adapter_message(message) when is_map(message) do
    message
    |> Enum.reduce(%{}, fn
      {key, value}, map when key in ["role", "content", "tool_calls", "tool_call_id"] ->
        value =
          cond do
            key == "role" and is_binary(value) -> role(value)
            key == "tool_calls" -> adapter_value("tool_calls", value)
            true -> value
          end

        Map.put(map, String.to_existing_atom(key), value)

      _field, map ->
        map
    end)
  end

  defp adapter_message(message), do: message

  defp adapter_tool_call(call) when is_map(call) do
    call
    |> Enum.reduce(%{}, fn
      {key, value}, map when key in ["id", "type", "function"] ->
        value = if key == "function", do: adapter_function(value), else: value
        Map.put(map, String.to_existing_atom(key), value)

      _field, map ->
        map
    end)
  end

  defp adapter_tool_call(call), do: call

  defp adapter_function(function) when is_map(function) do
    function
    |> Map.take(~w(name arguments))
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp adapter_function(function), do: function
  defp role("system"), do: :system
  defp role("user"), do: :user
  defp role("assistant"), do: :assistant
  defp role("tool"), do: :tool
  defp role(role), do: role

  defp safe_directory(directory, relative) do
    cond do
      not String.valid?(relative) or byte_size(relative) not in 1..1_024 ->
        {:error, :unsafe_provider_path}

      Path.type(relative) != :relative or
          Enum.any?(Path.split(relative), &(&1 in ["", ".", ".."])) ->
        {:error, :unsafe_provider_path}

      true ->
        relative
        |> Path.split()
        |> Enum.reduce_while({:ok, directory}, fn segment, {:ok, parent} ->
          path = Path.join(parent, segment)

          case File.lstat(path) do
            {:ok, %{type: :directory}} -> {:cont, {:ok, path}}
            _ -> {:halt, {:error, :unsafe_provider_path}}
          end
        end)
    end
  end

  defp exact_keys(map, allowed, required) do
    keys = Map.keys(map)
    if keys -- allowed == [] and required -- keys == [], do: :ok, else: {:error, :invalid_config}
  end

  defp valid_name?(name),
    do: is_binary(name) and name =~ ~r/\A[a-z][a-z0-9._-]{0,127}\z/
end
