defmodule PtcRunner.Kernel.LLMReplayFixtureDiagnostic do
  @moduledoc false

  # Why a fixture file was refused, as a closed set of reasons a fixture author
  # can act on.
  #
  # A rejected line has a number, and a number is safe to publish: it locates
  # the mistake without carrying any of the prompt, transcript, or response the
  # line holds. The rule the line broke is equally safe, because every rule here
  # is part of the published fixture contract. Nothing else about the line
  # crosses this boundary — not its bytes, not its length, not its hash.
  #
  # The file-level reasons carry no number because they are properties of the
  # file rather than of any one line.

  alias PtcRunner.Kernel.DiagnosticPattern

  @file_reasons [
    {:replay_fixtures_unreadable, "the replay fixture file could not be read"},
    {:replay_fixtures_empty, "the replay fixture file has no entries"},
    {:replay_fixtures_too_large, "the replay fixture file exceeds its 8 MB ceiling"}
  ]

  @line_prefix "replay fixture line "
  @line_reasons [
    {:invalid_json, "is not valid JSON"},
    {:entry_not_an_object, "is not a JSON object"},
    {:unknown_entry_key,
     "has a key outside schema_version, request_hash, response, and responses"},
    {:schema_version_invalid, "must set schema_version to 1"},
    {:request_hash_invalid,
     "must set request_hash to sha256: followed by 64 lowercase hexadecimal characters"},
    {:response_missing, "must set exactly one of response or responses"},
    {:response_ambiguous, "sets both response and responses; use exactly one"},
    {:responses_invalid, "must set responses to a sequence of 1 through 1024 JSON objects"},
    {:response_too_large, "declares a response larger than the installed result ceiling"},
    {:duplicate_entry, "repeats a request_hash an earlier line already claimed"},
    {:entry_limit_exceeded, "exceeds the installed replay entry ceiling"}
  ]

  # An 8 MB fixture cannot hold more lines than this, so the bound is a fact
  # about the ceiling rather than a chosen ration.
  @maximum_line 8_000_000
  @line_pattern "(?:[1-9][0-9]{0,5}|[1-7][0-9]{6}|8000000)"

  @file_messages Enum.map(@file_reasons, fn {_reason, message} -> message end)
  @line_bodies Enum.map(@line_reasons, fn {_reason, body} -> body end)
  @maximum_message_bytes Enum.max(
                           Enum.map(@file_messages, &byte_size/1) ++
                             Enum.map(
                               @line_bodies,
                               &(byte_size(@line_prefix) + 7 + 1 + byte_size(&1))
                             )
                         )

  @type reason :: atom() | {atom(), pos_integer()}

  @doc "Renders the bounded public message for one fixture-load reason."
  @spec message(term()) :: {:ok, binary()} | :error
  for {reason, message} <- @file_reasons do
    def message(unquote(reason)), do: {:ok, unquote(message)}
  end

  for {reason, body} <- @line_reasons do
    def message({unquote(reason), line}) when is_integer(line) and line in 1..@maximum_line,
      do: {:ok, @line_prefix <> Integer.to_string(line) <> " " <> unquote(body)}
  end

  def message(_reason), do: :error

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message),
    do: message in @file_messages or valid_line_message?(message)

  def valid_message?(_message), do: false

  defp valid_line_message?(@line_prefix <> rest) do
    case :binary.split(rest, " ") do
      [digits, body] -> valid_line?(digits) and body in @line_bodies
      _no_body -> false
    end
  end

  defp valid_line_message?(_message), do: false

  defp valid_line?(digits) do
    case Integer.parse(digits) do
      {line, ""} -> Integer.to_string(line) == digits and line in 1..@maximum_line
      _invalid -> false
    end
  end

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    %{
      "oneOf" =>
        [%{"const" => fallback}] ++
          Enum.map(@file_messages, &%{"const" => &1}) ++
          [
            %{
              "type" => "string",
              "minLength" => 1,
              "maxLength" => @maximum_message_bytes,
              "pattern" =>
                DiagnosticPattern.exact(
                  DiagnosticPattern.escape(@line_prefix) <>
                    @line_pattern <>
                    " (?:" <>
                    Enum.map_join(@line_bodies, "|", &DiagnosticPattern.escape/1) <> ")"
                )
            }
          ]
    }
  end
end
