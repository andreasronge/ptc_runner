defmodule PtcRunner.Kernel.RunCatalogSnapshot do
  @moduledoc """
  Owner process holding one immutable private run-catalog generation.

  Capture runs once, inside a heap- and deadline-bounded worker, and freezes
  its rows into owner state. Nothing re-lists or re-probes afterwards, so a
  filesystem that grows, shrinks, or changes under an open generation cannot
  alter what this owner answers; a caller that wants current state captures a
  new generation, which carries a different `catalog_digest`.

  The owner is bound to the process that started it and exits when that owner
  does. It holds no file descriptors: every probe closes its file before the
  capture returns, so a generation costs bounded memory and no handles.

  This owner is the discovery half of the two-stage cohort contract. It never
  opens a private payload and never admits a source — selection admission
  re-verifies the files it names, on its own authority.
  """

  use GenServer

  alias PtcRunner.Kernel.BoundedCapture
  alias PtcRunner.Kernel.RunCatalog
  alias PtcRunner.Kernel.RunCatalogProbe
  alias PtcRunner.Lisp.RetainedSize

  @default_retained_bytes 4_194_304
  @capture_heap_words 10_000_000
  @capture_timeout_ms 15_000
  @default_directory_entries RunCatalogProbe.default_directory_entries()
  @default_files RunCatalogProbe.default_files()

  @enforce_keys [:pid, :token]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{pid: pid(), token: reference()}

  @spec default_retained_bytes() :: pos_integer()
  def default_retained_bytes, do: @default_retained_bytes

  @doc """
  Captures one generation over a trace root and an inspection root.

  Options lower, never raise, the capture bounds: `:max_directory_entries`,
  `:max_files`, `:max_retained_bytes`, `:capture_heap_words`, and
  `:capture_deadline_ms`. `:owner` names the process the generation belongs
  to, and `:listing_hook` and `:file_probe_hook` exist for tests that need
  deterministic synchronization around filesystem operations.

  Whole-operation refusals are path-free: `:source_unavailable` for a root
  that cannot be listed, and `:catalog_limit_exceeded` for a listing, stem
  count, or retained projection beyond its bound.
  """
  @spec start({:private_authorized_catalog, binary(), binary()}, keyword()) ::
          {:ok, t()} | {:error, atom()}
  def start(source, opts \\ [])

  def start({:private_authorized_catalog, traces, inspection}, opts)
      when is_binary(traces) and is_binary(inspection) and is_list(opts) do
    allowed = [
      :owner,
      :max_directory_entries,
      :max_files,
      :max_retained_bytes,
      :capture_heap_words,
      :capture_deadline_ms,
      :listing_hook,
      :file_probe_hook
    ]

    with true <- Keyword.keys(opts) -- allowed == [],
         owner when is_pid(owner) <- Keyword.get(opts, :owner, self()),
         max_directory_entries when max_directory_entries in 1..@default_directory_entries <-
           Keyword.get(opts, :max_directory_entries, @default_directory_entries),
         max_files when max_files in 1..@default_files <-
           Keyword.get(opts, :max_files, @default_files),
         max_retained_bytes when max_retained_bytes in 1..@default_retained_bytes <-
           Keyword.get(opts, :max_retained_bytes, @default_retained_bytes),
         capture_heap_words when capture_heap_words in 233..@capture_heap_words <-
           Keyword.get(opts, :capture_heap_words, @capture_heap_words),
         capture_deadline_ms when is_integer(capture_deadline_ms) <-
           Keyword.get(
             opts,
             :capture_deadline_ms,
             System.monotonic_time(:millisecond) + @capture_timeout_ms
           ),
         listing_hook when is_nil(listing_hook) or is_function(listing_hook, 0) <-
           Keyword.get(opts, :listing_hook),
         file_probe_hook when is_nil(file_probe_hook) or is_function(file_probe_hook, 2) <-
           Keyword.get(opts, :file_probe_hook) do
      token = make_ref()

      config = %{
        traces: traces,
        inspection: inspection,
        owner: owner,
        token: token,
        max_directory_entries: max_directory_entries,
        max_files: max_files,
        max_retained_bytes: max_retained_bytes,
        capture_heap_words: capture_heap_words,
        capture_deadline_ms: capture_deadline_ms,
        listing_hook: listing_hook,
        file_probe_hook: file_probe_hook
      }

      case GenServer.start(__MODULE__, config) do
        {:ok, pid} -> {:ok, %__MODULE__{pid: pid, token: token}}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        {:error, _reason} -> {:error, :source_unavailable}
      end
    else
      _invalid -> {:error, :invalid_catalog}
    end
  end

  def start(_source, _opts), do: {:error, :invalid_catalog}

  @doc """
  Returns the generation's frozen rows, in run-reference order.

  The list is bounded by the capture's retained-byte and stem-count limits.
  Paging, filtering, and digest-bound cursors are the query surface's concern
  and read the same frozen list.
  """
  @spec rows(t()) :: {:ok, [RunCatalog.row()]} | {:error, atom()}
  def rows(%__MODULE__{} = snapshot), do: call(snapshot, :rows)
  def rows(_snapshot), do: {:error, :invalid_catalog}

  @doc "Returns the generation's identity and accounting, without any row."
  @spec info(t()) :: {:ok, map()} | {:error, atom()}
  def info(%__MODULE__{} = snapshot), do: call(snapshot, :info)
  def info(_snapshot), do: {:error, :invalid_catalog}

  @spec stop(term()) :: :ok
  def stop(%__MODULE__{} = snapshot) do
    _result = call(snapshot, :stop)
    :ok
  end

  def stop(_snapshot), do: :ok

  @doc false
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{pid: pid}), do: Process.alive?(pid)

  @impl GenServer
  def init(config) do
    owner_ref = Process.monitor(config.owner)

    case capture_for_owner(config, owner_ref) do
      {:ok, generation, retained_bytes} ->
        {:ok,
         %{
           token: config.token,
           owner_ref: owner_ref,
           rows: generation.rows,
           info: %{
             source: :ptc_run_catalog,
             catalog_digest: generation.catalog_digest,
             row_count: length(generation.rows),
             excluded_files: generation.excluded_files,
             retained_bytes: retained_bytes
           }
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({token, :info}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.info}, state}

  def handle_call({token, :rows}, _from, %{token: token} = state),
    do: {:reply, {:ok, state.rows}, state}

  def handle_call({token, :stop}, _from, %{token: token} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call({_token, _request}, _from, state),
    do: {:reply, {:error, :invalid_catalog}, state}

  def handle_call(_request, _from, state), do: {:reply, {:error, :invalid_catalog}, state}

  @impl GenServer
  # ex_dna:disable-for-next-line — GenServer callbacks, intentionally per-module.
  # An owner's reaction to its owner's death and the redaction of its own state
  # are part of that owner's contract; routing them through a shared module
  # would couple the lifecycles of otherwise independent snapshots.
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  # ex_dna:disable-for-next-line — see the note on handle_cast/2 above.
  def handle_info({:DOWN, owner_ref, :process, _owner, _reason}, %{owner_ref: owner_ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  # This OTP-version guard around `format_status/1` is byte-identical in the
  # twelve other owner modules that carry it. A suppression comment does not
  # attach to a bare module-level `if`, so this occurrence joins that cluster
  # in `.duplication-baseline.json` rather than being marked here.
  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  defp redact_status(status) when is_map(status), do: Map.put(status, :state, :redacted)
  defp redact_status(status), do: status

  defp call(%__MODULE__{pid: pid, token: token}, request) when is_pid(pid) do
    GenServer.call(pid, {token, request}, :infinity)
  catch
    :exit, _reason -> {:error, :catalog_unavailable}
  end

  defp call(_snapshot, _request), do: {:error, :invalid_catalog}

  # A root wider than the capture's heap allowance is refused as a limit, not
  # reported as an unavailable source: the files were readable, the projection
  # was not affordable.
  defp capture_for_owner(config, owner_ref) do
    case BoundedCapture.for_owner(fn -> capture(config) end,
           owner: config.owner,
           owner_ref: owner_ref,
           max_heap_words: config.capture_heap_words,
           deadline_ms: config.capture_deadline_ms
         ) do
      {:ok, result} -> result
      {:error, :owner_down} -> {:error, :catalog_unavailable}
      {:error, :heap_exceeded} -> {:error, :catalog_limit_exceeded}
      {:error, _failure} -> {:error, :source_unavailable}
    end
  end

  defp capture(config) do
    with {:ok, %{probes: probes, excluded_files: excluded_files}} <-
           RunCatalogProbe.probe_all(config.traces, config.inspection,
             max_directory_entries: config.max_directory_entries,
             max_files: config.max_files,
             listing_hook: config.listing_hook,
             file_probe_hook: config.file_probe_hook
           ),
         {:ok, generation} <- RunCatalog.generation(probes, excluded_files) do
      retain(generation, config.max_retained_bytes)
    end
  end

  # Rows are detached from the probe buffers they were sliced out of before
  # they are measured and retained, so the generation owns the bytes it is
  # charged for rather than pinning whole head and tail windows.
  defp retain(generation, max_retained_bytes) do
    retained = RetainedSize.detach_binaries(generation)

    case RetainedSize.bytes_with_cap(retained, max_retained_bytes) do
      bytes when is_integer(bytes) and bytes <= max_retained_bytes -> {:ok, retained, bytes}
      _oversized -> {:error, :catalog_limit_exceeded}
    end
  end
end
