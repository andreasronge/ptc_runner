defmodule PtcRunner.Kernel.LLMReplay do
  @moduledoc """
  Serves language-model responses from a frozen fixture file.

  Evaluation needs a workflow LLM whose answers do not move between a baseline
  run and a candidate run, otherwise a behavioural difference cannot be
  attributed to the candidate. This is an installed host source rather than an
  Elixir test callback so an evaluation recipe stays ordinary configuration:
  the same manifest grammar selects a replay provider or a live one, and
  nothing about the application changes between them.

  A fixture file is JSON Lines. Every entry requires `"schema_version": 1`, a
  `request_hash` matching `sha256:` followed by 64 lowercase hexadecimal
  characters, and exactly one of `response` or `responses`. `response` is one
  JSON object. `responses` is an ordered, non-empty sequence of at most 1,024
  JSON objects. No other entry keys are accepted.

  For example, one line is:

      {"schema_version":1,"request_hash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","response":{"content":"frozen"}}

  The sequence form exists for a request that repeats *identically* — a retry,
  or a loop that rebuilds the same prompt — where the first call gets the first
  element and the next call the next. An ordinary multi-turn agent loop does
  not need it: each turn carries the accumulated transcript, so each request
  hashes differently and gets its own entry.

  The hash is over the deterministic encoding of the provider-neutral request
  the workflow actually built, before any provider adapter sees it, so a
  fixture is not tied to the vendor that recorded it. That also makes the match
  exact by construction: a run whose prompt, messages, tools, or schema differ
  at all produces a different hash and fails rather than silently replaying a
  response recorded for a different question. A normal-data miss reports the computed
  hash as
  `no replay fixture matches this request (request_hash: sha256:...)` in command
  output and private capability inspection. A private-data run keeps the hash
  out of its public command diagnostic because the unsalted request hash could
  reveal equality or permit guesses of low-entropy prompts; author those
  fixtures from the owner-only inspection record instead. Copy the hash into
  the entry, provide the response the workflow expects, and rerun.

  The provider is owned. Its response cursor lives in a process that monitors
  the run that acquired it, so a run failing between acquisition and cleanup
  cannot leave a replay owner behind.

  Every failure is closed. An unknown hash, an exhausted sequence, a malformed
  or oversized response, a duplicate entry, or a fixture past its ceilings all
  fail the call rather than inventing or reusing a response. Nothing here
  performs network activity, and the safe snapshot carries the format version,
  fixture-set hash, entry counts, and ceilings — never a payload or a path.

  Load failures name the rule that refused the file. A rejected line reports
  `{reason, line}`, and the line number is the number in the file, blank lines
  counted, so a fixture author can open the file at the offending line. The
  reason and the number are the only per-line detail that crosses the boundary;
  the line's bytes never do.
  """

  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.LLMReplayDiagnostic
  alias PtcRunner.Kernel.LLMReplayOwner
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.Lisp.RetainedSize

  @format_version 1
  @max_fixture_bytes 8_000_000
  @entry_keys ~w(schema_version request_hash response responses)
  @hash ~r/\Asha256:[0-9a-f]{64}\z/

  @enforce_keys [:pid, :entry_count, :response_count, :fixture_hash, :max_result_bytes]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          pid: pid(),
          entry_count: non_neg_integer(),
          response_count: non_neg_integer(),
          fixture_hash: binary(),
          max_result_bytes: pos_integer()
        }

  @type entry_reason ::
          :invalid_json
          | :entry_not_an_object
          | :unknown_entry_key
          | :schema_version_invalid
          | :request_hash_invalid
          | :response_missing
          | :response_ambiguous
          | :responses_invalid
          | :response_too_large
          | :duplicate_entry
          | :entry_limit_exceeded

  @type error ::
          :replay_fixtures_unreadable
          | :replay_fixtures_empty
          | :replay_fixtures_too_large
          | :replay_owner_unavailable
          | :resource_registrar_unavailable
          | {entry_reason(), pos_integer()}

  @type fixture_summary :: %{
          entry_count: pos_integer(),
          response_count: pos_integer(),
          fixture_hash: binary(),
          max_result_bytes: pos_integer()
        }

  @doc """
  Loads one fixture file and starts the owner that tracks sequence position.

  `directory` is the trusted host-config directory the relative `path` is
  confined to. `max_entries` bounds distinct request hashes and
  `max_result_bytes` bounds one replayed response.
  """
  @spec start(binary(), binary(), keyword()) :: {:ok, t()} | {:error, error()}
  def start(directory, path, opts \\ [])
      when is_binary(directory) and is_binary(path) and is_list(opts) do
    max_entries = Keyword.fetch!(opts, :max_entries)
    max_result_bytes = Keyword.fetch!(opts, :max_result_bytes)
    owner = Keyword.get(opts, :owner, self())
    registrar = Keyword.get(opts, :resource_registrar)

    with {:ok, raw, entries} <- load_fixtures(directory, path, max_entries, max_result_bytes),
         {:ok, pid} <- start_owner(entries, owner, registrar) do
      {:ok,
       %__MODULE__{
         pid: pid,
         entry_count: map_size(entries),
         response_count:
           Enum.reduce(entries, 0, fn {_hash, list}, total -> total + length(list) end),
         fixture_hash: hash(raw),
         max_result_bytes: max_result_bytes
       }}
    end
  end

  @doc """
  Validates one fixture file without starting its response-cursor owner.

  Doctor uses this bounded, process-free probe before provider activity. It
  reads and parses the same bytes under the same ceilings as `start/3`, so a
  passing local check cannot disagree with acquisition about fixture validity.
  """
  @spec probe(binary(), binary(), keyword()) :: {:ok, fixture_summary()} | {:error, error()}
  def probe(directory, path, opts)
      when is_binary(directory) and is_binary(path) and is_list(opts) do
    max_entries = Keyword.fetch!(opts, :max_entries)
    max_result_bytes = Keyword.fetch!(opts, :max_result_bytes)

    with {:ok, raw, entries} <-
           load_fixtures(directory, path, max_entries, max_result_bytes) do
      {:ok,
       %{
         entry_count: map_size(entries),
         response_count:
           Enum.reduce(entries, 0, fn {_hash, list}, total -> total + length(list) end),
         fixture_hash: hash(raw),
         max_result_bytes: max_result_bytes
       }}
    end
  end

  def probe(_directory, _path, _opts), do: {:error, :replay_fixtures_unreadable}

  @doc """
  Returns the requester `LLMCapability` calls, so replay and live installations
  present the identical provider-facing contract.
  """
  @spec requester(t()) :: (map() -> {:ok, map()} | {:error, ProviderError.t()})
  def requester(%__MODULE__{} = replay) do
    fn request -> respond(replay, request) end
  end

  @doc "Stops the owner. Safe to call more than once."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{pid: pid}), do: LLMReplayOwner.stop(pid)

  @doc """
  Safe provider identity. Carries counts and ceilings, never payloads or paths.
  """
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = replay) do
    %{
      "source" => "llm_replay",
      "format_version" => @format_version,
      "fixture_set_hash" => replay.fixture_hash,
      "entry_count" => replay.entry_count,
      "response_count" => replay.response_count,
      "max_result_bytes" => replay.max_result_bytes
    }
  end

  @doc """
  Hashes a provider-neutral request the way fixture keys are computed.

  Manifest authors normally copy the hash from a replay-miss command error;
  this function supports embedders that already hold the provider-neutral
  request map.
  """
  @spec request_hash(map()) :: {:ok, binary()} | :error
  def request_hash(request) when is_map(request) do
    case DeterministicJSON.encode(request) do
      {:ok, encoded} -> {:ok, hash(encoded)}
      _other -> :error
    end
  end

  def request_hash(_request), do: :error

  # One atomic take: reading the remaining responses and advancing the cursor
  # must not be two operations, or two concurrent workflow calls could replay
  # the same element.
  defp respond(%__MODULE__{} = replay, request) do
    with {:ok, key} <- hash_request(request),
         {:ok, response} <- take(replay, key) do
      bounded(response, replay.max_result_bytes)
    end
  end

  defp hash_request(request) do
    case request_hash(request) do
      {:ok, key} ->
        {:ok, key}

      :error ->
        {:error, ProviderError.new(:invalid_request, "replay request could not be normalized")}
    end
  end

  defp take(%__MODULE__{pid: pid}, key) do
    case LLMReplayOwner.take(pid, key) do
      {:ok, response} ->
        {:ok, response}

      {:error, :exhausted} ->
        {:error, failure("replay sequence for this request is exhausted")}

      {:error, :unmatched} ->
        {:ok, details} = LLMReplayDiagnostic.message(key)
        {:error, failure(details, key)}

      {:error, :unavailable} ->
        {:error, ProviderError.new(:unavailable, "replay provider is unavailable")}
    end
  end

  defp bounded(response, limit) do
    bytes = RetainedSize.bytes_with_cap(response, limit)

    if is_integer(bytes) and bytes <= limit,
      do: {:ok, response},
      else:
        {:error,
         ProviderError.new(:invalid_result, "replay response exceeds its configured ceiling")}
  end

  # Not retryable: a fixture set is frozen, so the same request will miss
  # again. Retrying would only burn the run's turn budget.
  defp failure(details), do: ProviderError.new(:not_found, details, retryable?: false)

  defp failure(details, request_hash) do
    ProviderError.new(:not_found, details,
      retryable?: false,
      replay_request_hash: request_hash
    )
  end

  defp read_fixtures(directory, path) do
    case ConfinedFile.read(directory, path, @max_fixture_bytes) do
      {:ok, raw} when byte_size(raw) > 0 -> {:ok, raw}
      {:ok, _empty} -> {:error, :replay_fixtures_empty}
      {:error, :too_large} -> {:error, :replay_fixtures_too_large}
      _reason -> {:error, :replay_fixtures_unreadable}
    end
  end

  defp load_fixtures(directory, path, max_entries, max_result_bytes) do
    with {:ok, raw} <- read_fixtures(directory, path),
         {:ok, entries} <- parse(raw, max_entries, max_result_bytes) do
      {:ok, raw, entries}
    end
  end

  # Line numbers are assigned before blank lines are dropped, so a reported
  # number is the number the author's editor shows rather than a count of the
  # lines that survived filtering.
  defp parse(raw, max_entries, max_result_bytes) do
    raw
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _number} -> String.trim(line) == "" end)
    |> Enum.reduce_while({:ok, %{}}, fn {line, number}, {:ok, entries} ->
      case entry(line, max_result_bytes) do
        {:ok, key, _responses} when is_map_key(entries, key) ->
          {:halt, {:error, {:duplicate_entry, number}}}

        {:ok, _key, _responses} when map_size(entries) >= max_entries ->
          {:halt, {:error, {:entry_limit_exceeded, number}}}

        {:ok, key, responses} ->
          {:cont, {:ok, Map.put(entries, key, responses)}}

        {:error, reason} ->
          {:halt, {:error, {reason, number}}}
      end
    end)
    |> case do
      {:ok, entries} when map_size(entries) > 0 -> {:ok, entries}
      {:ok, _empty} -> {:error, :replay_fixtures_empty}
      error -> error
    end
  end

  # One rejection per rule. Collapsing these into a single reason is what made a
  # fixture unauthorable: eight different mistakes produced one sentence that
  # named none of them.
  defp entry(line, max_result_bytes) do
    with {:ok, value} <- decoded_object(line),
         :ok <- known_keys(value),
         :ok <- schema_version(value),
         {:ok, key} <- request_hash_key(value),
         {:ok, responses} <- responses(value),
         :ok <- bounded_responses(responses, max_result_bytes) do
      {:ok, key, responses}
    end
  end

  defp decoded_object(line) do
    case StrictJSON.decode(line) do
      {:ok, value} ->
        detached = RetainedSize.detach_binaries(value)

        if is_map(detached) and not is_struct(detached),
          do: {:ok, detached},
          else: {:error, :entry_not_an_object}

      _invalid ->
        {:error, :invalid_json}
    end
  end

  defp known_keys(value) do
    if Map.keys(value) -- @entry_keys == [], do: :ok, else: {:error, :unknown_entry_key}
  end

  defp schema_version(%{"schema_version" => @format_version}), do: :ok
  defp schema_version(_value), do: {:error, :schema_version_invalid}

  defp request_hash_key(%{"request_hash" => key}) when is_binary(key) do
    if key =~ @hash, do: {:ok, key}, else: {:error, :request_hash_invalid}
  end

  defp request_hash_key(_value), do: {:error, :request_hash_invalid}

  # Exactly one of `response` or `responses`: accepting both would leave the
  # replay order ambiguous, whatever either one holds.
  defp responses(%{"response" => _response, "responses" => _sequence}),
    do: {:error, :response_ambiguous}

  defp responses(%{"response" => response}) when is_map(response), do: {:ok, [response]}
  defp responses(%{"response" => _response}), do: {:error, :responses_invalid}

  defp responses(%{"responses" => sequence}) when is_list(sequence) do
    if length(sequence) in 1..1_024 and Enum.all?(sequence, &is_map/1),
      do: {:ok, sequence},
      else: {:error, :responses_invalid}
  end

  defp responses(%{"responses" => _sequence}), do: {:error, :responses_invalid}
  defp responses(_value), do: {:error, :response_missing}

  defp bounded_responses(responses, max_result_bytes) do
    cond do
      not Enum.all?(responses, &JSONValue.map?/1) ->
        {:error, :responses_invalid}

      not Enum.all?(responses, &within_ceiling?(&1, max_result_bytes)) ->
        {:error, :response_too_large}

      true ->
        :ok
    end
  end

  defp within_ceiling?(response, max_result_bytes) do
    bytes = RetainedSize.bytes_with_cap(response, max_result_bytes)
    is_integer(bytes) and bytes <= max_result_bytes
  end

  defp start_owner(entries, owner, registrar) do
    case LLMReplayOwner.start(entries, owner, registrar) do
      {:ok, pid} -> {:ok, pid}
      {:error, :resource_registrar_unavailable} = error -> error
      _reason -> {:error, :replay_owner_unavailable}
    end
  end

  defp hash(binary), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, binary), case: :lower)
end
