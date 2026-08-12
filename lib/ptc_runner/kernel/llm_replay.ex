defmodule PtcRunner.Kernel.LLMReplay do
  @moduledoc """
  Serves language-model responses from a frozen fixture file.

  Evaluation needs a workflow LLM whose answers do not move between a baseline
  run and a candidate run, otherwise a behavioural difference cannot be
  attributed to the candidate. This is an installed host source rather than an
  Elixir test callback so an evaluation recipe stays ordinary configuration:
  the same manifest grammar selects a replay provider or a live one, and
  nothing about the application changes between them.

  A fixture file is JSON Lines. Each entry names the `request_hash` it answers
  and carries either one `response` or an ordered `responses` sequence. The
  sequence form exists for a request that repeats *identically* — a retry, or a
  loop that rebuilds the same prompt — where the first call gets the first
  element and the next call the next. An ordinary multi-turn agent loop does
  not need it: each turn carries the accumulated transcript, so each request
  hashes differently and gets its own entry.

  The hash is over the deterministic encoding of the provider-neutral request
  the workflow actually built, before any provider adapter sees it, so a
  fixture is not tied to the vendor that recorded it. That also makes the match
  exact by construction: a run whose prompt, messages, or tools differ at all
  produces a different hash and fails rather than silently replaying a response
  recorded for a different question.

  The provider is owned. Its response cursor lives in a process that monitors
  the run that acquired it, so a run failing between acquisition and cleanup
  cannot leave a replay owner behind.

  Every failure is closed. An unknown hash, an exhausted sequence, a malformed
  or oversized response, a duplicate entry, or a fixture past its ceilings all
  fail the call rather than inventing or reusing a response. Nothing here
  performs network activity, and the safe snapshot carries the format version,
  fixture-set hash, entry counts, and ceilings — never a payload or a path.
  """

  alias PtcRunner.Kernel.ConfinedFile
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.JSONValue
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

  @type error ::
          :invalid_replay_fixtures
          | :replay_fixtures_too_large
          | :duplicate_replay_entry
          | :replay_entry_limit_exceeded
          | :resource_registrar_unavailable

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

    with {:ok, raw} <- read_fixtures(directory, path),
         {:ok, entries} <- parse(raw, max_entries, max_result_bytes),
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

  @doc "Hashes a provider-neutral request the way fixture keys are computed."
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
        {:error, failure("no replay fixture matches this request")}

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

  defp read_fixtures(directory, path) do
    case ConfinedFile.read(directory, path, @max_fixture_bytes) do
      {:ok, raw} when byte_size(raw) > 0 -> {:ok, raw}
      {:error, :too_large} -> {:error, :replay_fixtures_too_large}
      _reason -> {:error, :invalid_replay_fixtures}
    end
  end

  defp parse(raw, max_entries, max_result_bytes) do
    raw
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, entries} ->
      case entry(line, max_result_bytes) do
        {:ok, key, _responses} when is_map_key(entries, key) ->
          {:halt, {:error, :duplicate_replay_entry}}

        {:ok, _key, _responses} when map_size(entries) >= max_entries ->
          {:halt, {:error, :replay_entry_limit_exceeded}}

        {:ok, key, responses} ->
          {:cont, {:ok, Map.put(entries, key, responses)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} when map_size(entries) > 0 -> {:ok, entries}
      {:ok, _empty} -> {:error, :invalid_replay_fixtures}
      error -> error
    end
  end

  defp entry(line, max_result_bytes) do
    with {:ok, value} <- StrictJSON.decode(line),
         value = RetainedSize.detach_binaries(value),
         true <- is_map(value) and not is_struct(value),
         true <- Map.keys(value) -- @entry_keys == [],
         @format_version <- value["schema_version"],
         key when is_binary(key) <- value["request_hash"],
         true <- key =~ @hash,
         {:ok, responses} <- responses(value),
         true <- Enum.all?(responses, &valid_response?(&1, max_result_bytes)) do
      {:ok, key, responses}
    else
      _reason -> {:error, :invalid_replay_fixtures}
    end
  end

  # Exactly one of `response` or `responses`: accepting both would leave the
  # replay order ambiguous.
  defp responses(%{"response" => response, "responses" => _sequence}) when is_map(response),
    do: :error

  defp responses(%{"response" => response}) when is_map(response), do: {:ok, [response]}

  defp responses(%{"responses" => sequence})
       when is_list(sequence) and length(sequence) in 1..1_024 do
    if Enum.all?(sequence, &is_map/1), do: {:ok, sequence}, else: :error
  end

  defp responses(_value), do: :error

  defp valid_response?(response, max_result_bytes) do
    bytes = RetainedSize.bytes_with_cap(response, max_result_bytes)
    JSONValue.map?(response) and is_integer(bytes) and bytes <= max_result_bytes
  end

  defp start_owner(entries, owner, registrar) do
    case LLMReplayOwner.start(entries, owner, registrar) do
      {:ok, pid} -> {:ok, pid}
      {:error, :resource_registrar_unavailable} = error -> error
      _reason -> {:error, :invalid_replay_fixtures}
    end
  end

  defp hash(binary), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, binary), case: :lower)
end
