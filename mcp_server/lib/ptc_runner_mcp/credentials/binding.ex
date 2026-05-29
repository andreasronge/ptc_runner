defmodule PtcRunnerMcp.Credentials.Binding do
  @moduledoc """
  Typed representation of a single entry in the `credentials:` config
  block, plus the pure-function parser that validates raw JSON-decoded
  binding specs into a `Binding.t()` struct.

  Source-layer knowledge only — this module never reads `System.get_env/1`,
  never opens a file, and never executes a command. Resolution
  (materialization) is the job of `PtcRunnerMcp.Credentials.materialize/1`.

  Spec: `Plans/http-transport-credentials.md` §5.4, §5.4.1, §5.4.2,
  §5.5 ##1, 4, 7 (first bullet), 11, and §7.2.

  v1 ships three sources: `:env`, `:file`, `:literal`. The `exec` source
  name is reserved and rejected at config-load with a "deferred to v1.1"
  error per §5.5 #11.
  """

  alias __MODULE__

  @type source :: :env | :file | :literal | :exec
  @type scheme_hint :: :bearer | :basic | :raw | nil

  @type t :: %__MODULE__{
          name: String.t(),
          source: source(),
          scheme_hint: scheme_hint(),
          spec: map()
        }

  defstruct [:name, :source, :scheme_hint, :spec]

  # Whitelisted source-string → atom map. We never call
  # `String.to_atom/1` on user input (AGENTS.md / usage rules).
  @sources %{
    "env" => :env,
    "file" => :file,
    "literal" => :literal,
    "exec" => :exec
  }

  @scheme_hints %{
    "bearer" => :bearer,
    "basic" => :basic,
    "raw" => :raw
  }

  # Top-level keys allowed in any binding spec. Source-specific keys
  # are validated separately per source.
  @common_keys ~w(source scheme_hint)
  @source_keys %{
    :env => ~w(var),
    :file => ~w(path),
    :literal => ~w(value),
    # `exec` is rejected before key validation runs.
    :exec => []
  }

  @env_var_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @binding_name_re ~r/^[a-zA-Z][a-zA-Z0-9_-]*$/

  @doc """
  Parse the entire `credentials:` block (a map of `name => raw_spec`)
  into a map of `name => Binding.t()`.

  An empty or `nil` block returns `{:ok, %{}}`. On the first failure,
  returns `{:error, reason, detail}` with the offending binding name
  embedded in the detail string.

  Each binding name **MUST** match `~r/^[a-zA-Z][a-zA-Z0-9_-]*$/` so
  the name is safe to interpolate into log lines without escaping.
  """
  @spec parse_block(map() | nil) ::
          {:ok, %{String.t() => t()}} | {:error, atom(), String.t()}
  def parse_block(nil), do: {:ok, %{}}

  def parse_block(block) when is_map(block) and map_size(block) == 0,
    do: {:ok, %{}}

  def parse_block(block) when is_map(block) do
    Enum.reduce_while(block, {:ok, %{}}, fn {name, raw}, {:ok, acc} ->
      with :ok <- validate_binding_name(name),
           {:ok, binding} <- parse(name, raw) do
        {:cont, {:ok, Map.put(acc, name, binding)}}
      else
        {:error, _reason, _detail} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Parse a single raw binding spec (the value side of the
  `credentials:` map) into a `Binding.t()`.

  Validates spec **shape only**. Does not resolve the source — does not
  read environment variables, does not open files. Resolution is in
  `PtcRunnerMcp.Credentials.materialize/1` (Phase 1B).
  """
  @spec parse(String.t(), map()) ::
          {:ok, t()} | {:error, atom(), String.t()}
  def parse(name, raw) when is_binary(name) and is_map(raw) do
    with {:ok, source} <- parse_source(name, raw),
         :ok <- reject_exec(name, source),
         :ok <- validate_keys(name, source, raw),
         {:ok, scheme_hint} <- parse_scheme_hint(name, raw),
         {:ok, spec} <- parse_source_spec(name, source, raw) do
      {:ok,
       %Binding{
         name: name,
         source: source,
         scheme_hint: scheme_hint,
         spec: spec
       }}
    end
  end

  def parse(name, _raw) when is_binary(name) do
    {:error, :invalid_spec, "binding '#{name}' spec must be a map (got non-map value)"}
  end

  # --- internals ---------------------------------------------------------

  defp validate_binding_name(name) when is_binary(name) do
    if Regex.match?(@binding_name_re, name) do
      :ok
    else
      {:error, :invalid_binding_name,
       "binding name '#{inspect(name)}' must match #{inspect(@binding_name_re.source)} " <>
         "(letters, digits, underscore, hyphen; must start with a letter)"}
    end
  end

  defp validate_binding_name(name) do
    {:error, :invalid_binding_name, "binding name must be a string, got #{inspect(name)}"}
  end

  defp parse_source(name, raw) do
    case Map.fetch(raw, "source") do
      {:ok, source_str} when is_binary(source_str) ->
        case Map.fetch(@sources, source_str) do
          {:ok, atom} ->
            {:ok, atom}

          :error ->
            {:error, :unknown_source,
             "binding '#{name}' has unknown source #{inspect(source_str)}; " <>
               "expected one of: env, file, literal"}
        end

      {:ok, other} ->
        {:error, :unknown_source,
         "binding '#{name}' source must be a string, got #{inspect(other)}"}

      :error ->
        {:error, :missing_source, "binding '#{name}' is missing required field 'source'"}
    end
  end

  defp reject_exec(name, :exec) do
    {:error, :exec_deferred,
     "binding '#{name}' uses 'exec' source which is deferred to v1.1; " <>
       "set allow_exec_bindings: true (server-level flag, not yet implemented)"}
  end

  defp reject_exec(_name, _source), do: :ok

  defp validate_keys(name, source, raw) do
    allowed = @common_keys ++ Map.fetch!(@source_keys, source)
    extras = Map.keys(raw) -- allowed

    case extras do
      [] ->
        :ok

      _ ->
        {:error, :unknown_field,
         "binding '#{name}' has unknown field(s) #{inspect(extras)}; " <>
           "allowed for source #{inspect(source)}: #{inspect(allowed)}"}
    end
  end

  defp parse_scheme_hint(name, raw) do
    case Map.fetch(raw, "scheme_hint") do
      :error ->
        {:ok, nil}

      {:ok, str} when is_binary(str) ->
        case Map.fetch(@scheme_hints, str) do
          {:ok, atom} ->
            {:ok, atom}

          :error ->
            {:error, :unknown_scheme_hint,
             "binding '#{name}' has unknown scheme_hint #{inspect(str)}; " <>
               "expected one of: bearer, basic, raw"}
        end

      {:ok, other} ->
        {:error, :unknown_scheme_hint,
         "binding '#{name}' scheme_hint must be a string, got #{inspect(other)}"}
    end
  end

  defp parse_source_spec(name, :env, raw) do
    with {:ok, var} <- fetch_required_string(name, raw, "var") do
      if Regex.match?(@env_var_re, var) do
        {:ok, %{var: var}}
      else
        {:error, :invalid_env_var,
         "binding '#{name}' env var name #{inspect(var)} must match " <>
           "#{inspect(@env_var_re.source)}"}
      end
    end
  end

  defp parse_source_spec(name, :file, raw) do
    with {:ok, path} <- fetch_required_string(name, raw, "path") do
      {:ok, %{path: path}}
    end
  end

  defp parse_source_spec(name, :literal, raw) do
    case Map.fetch(raw, "value") do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, %{value: value}}

      {:ok, ""} ->
        {:error, :invalid_literal, "binding '#{name}' literal value must be a non-empty string"}

      {:ok, other} ->
        {:error, :invalid_literal,
         "binding '#{name}' literal value must be a string, got #{inspect(other)}"}

      :error ->
        {:error, :missing_field, "binding '#{name}' (literal) is missing required field 'value'"}
    end
  end

  defp fetch_required_string(name, raw, field) do
    case Map.fetch(raw, field) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, ""} ->
        {:error, :invalid_field, "binding '#{name}' field '#{field}' must be a non-empty string"}

      {:ok, other} ->
        {:error, :invalid_field,
         "binding '#{name}' field '#{field}' must be a string, got #{inspect(other)}"}

      :error ->
        {:error, :missing_field, "binding '#{name}' is missing required field '#{field}'"}
    end
  end
end
