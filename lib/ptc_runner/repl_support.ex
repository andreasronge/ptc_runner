defmodule PtcRunner.ReplSupport do
  @moduledoc false
  alias PtcRunner.Kernel.AnalysisProfileRegistry
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.ReplError

  def jsonl_reachable?(recipe, opts) do
    unattended = Keyword.get(opts, :private_unattended, false)
    :jsonl in AnalysisProfileRegistry.reachable_frontend(recipe, unattended).output_formats
  end

  def preview_chars(opts), do: Keyword.get(opts, :preview_chars, 2_048)

  def introspection_hint do
    ~S|Explore functions with (apropos "term") and (doc "name"); inspect attached APIs with (dir), (export-meta "ns/name"), and (source ns/name).|
  end

  def balanced?(source) do
    source
    |> String.graphemes()
    |> Enum.reduce_while({0, false, false}, fn
      _char, {depth, _quoted?, _escaped?} when depth < 0 -> {:halt, {-1, false, false}}
      "\\", {depth, true, false} -> {:cont, {depth, true, true}}
      _char, {depth, true, true} -> {:cont, {depth, true, false}}
      "\"", {depth, quoted?, false} -> {:cont, {depth, not quoted?, false}}
      "(", {depth, false, false} -> {:cont, {depth + 1, false, false}}
      ")", {depth, false, false} -> {:cont, {depth - 1, false, false}}
      _char, state -> {:cont, state}
    end)
    |> case do
      {0, false, false} -> true
      _state -> false
    end
  end

  def info(message), do: IO.puts(message)
  def error(message), do: IO.puts(:stderr, message)
  def fail(message), do: raise(ReplError, message: message)
  def fail(code, message), do: raise(ReplError, code: code, message: message)
  def terminal_hint(true), do: "\n" <> introspection_hint()
  def terminal_hint(false), do: ""

  @spec command_error(keyword(), atom(), map()) :: no_return()
  def command_error(opts, category, %{code: code, message: message})
      when is_atom(code) and is_binary(message),
      do: command_error(opts, category, code, message)

  @spec command_error(keyword(), atom(), binary()) :: no_return()
  def command_error(opts, category, message) when is_binary(message),
    do: command_error(opts, category, message, %{})

  @spec command_error(keyword(), atom(), atom(), binary()) :: no_return()
  def command_error(opts, category, code, message) when is_atom(code) and is_binary(message),
    do: command_error(opts, category, code, message, %{})

  @spec command_error(keyword(), atom(), binary(), map()) :: no_return()
  def command_error(opts, category, message, extra) when is_binary(message) and is_map(extra) do
    emit_command_error(opts, category, message, extra)
    fail(message)
  end

  @spec command_error(keyword(), atom(), atom(), binary(), map()) :: no_return()
  def command_error(opts, category, code, message, extra)
      when is_atom(code) and is_binary(message) and is_map(extra) do
    emit_command_error(opts, category, message, Map.put(extra, "code", Atom.to_string(code)))
    fail(code, message)
  end

  defp emit_command_error(opts, category, message, extra) do
    if output_format(opts) == :jsonl do
      emit_jsonl(
        Map.merge(
          %{
            "schema_version" => 1,
            "type" => "command-error",
            "category" => Atom.to_string(category),
            "message" => message
          },
          extra
        )
      )
    end
  end

  def output_format(opts),
    do: if(Keyword.get(opts, :format) == "jsonl", do: :jsonl, else: :clojure)

  def emit_jsonl(value) do
    case value |> json_projection() |> DeterministicJSON.encode() do
      {:ok, encoded} -> IO.puts(encoded)
      {:error, _reason} -> fail("ptc repl could not encode JSONL output")
    end
  end

  def json_projection(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, nested} -> {json_key(key), json_projection(nested)} end)
  end

  def json_projection(value) when is_list(value), do: Enum.map(value, &json_projection/1)
  def json_projection(value) when is_boolean(value) or is_nil(value), do: value
  def json_projection(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  def json_projection(value), do: value

  defp json_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.trim_trailing("?")
  defp json_key(key) when is_binary(key), do: key
end
