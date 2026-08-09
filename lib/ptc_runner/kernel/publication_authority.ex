defmodule PtcRunner.Kernel.PublicationAuthority do
  @moduledoc """
  Sealed, anchored artifact destinations authorized before execution.

  `authorize/4` is the phase-6 boundary. It captures physical parent and file
  identities and retains exclusive staging handles for normal artifacts. A
  private result additionally retains an empty, owner-only recovery file in
  the requested result directory. The authority is the only value passed into
  execution; execution outcomes retain only its attested binding.

  `new/1` remains an un-authorized value constructor for direct embedding
  validation and attestation tests. Production command paths use
  `authorize/4` before opening a provider session.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.DestinationIdentity
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.PublicationClaimOwner
  alias PtcRunner.Kernel.PublicationHandle
  alias PtcRunner.Kernel.TraceLog

  @destination_keys [:trace, :inspect, :output, :private_output]
  @option_keys @destination_keys ++ [:trace_dir, :run_ref]
  @enforce_keys @destination_keys ++
                  [
                    :run_ref,
                    :event_policy,
                    :provider_class,
                    :authorized?,
                    :attestation,
                    :lifecycle,
                    :claim_owner
                  ]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @opaque t :: %__MODULE__{
            trace: binary() | PublicationHandle.t() | nil,
            inspect: binary() | PublicationHandle.t() | nil,
            output: binary() | PublicationHandle.t() | nil,
            private_output:
              binary()
              | %{
                  requested: binary(),
                  requested_handle: PublicationHandle.t(),
                  recovery: PublicationHandle.t()
                }
              | nil,
            run_ref: binary() | nil,
            event_policy: :normal | :private,
            provider_class: :normal | :private_inspection,
            authorized?: boolean(),
            attestation: binary(),
            lifecycle: reference(),
            claim_owner: pid()
          }

  @type lease :: {pid(), reference()}
  @type artifact_destination :: :trace | :inspection | :result
  @type authorization_error :: atom() | {atom(), artifact_destination()}

  @doc false
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_publication_authority}
  def new(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         :ok <- validate_option_keys(opts),
         false <- Keyword.has_key?(opts, :trace_dir),
         :ok <- validate_unreserved_options(opts),
         lifecycle <- live_lifecycle(),
         {:ok, claim_owner} <- PublicationClaimOwner.start(lifecycle, self()),
         authority <- unreserved(opts, lifecycle, claim_owner),
         true <- fields_valid?(authority) do
      {:ok, attest(authority)}
    else
      _invalid -> {:error, :invalid_publication_authority}
    end
  end

  def new(_opts), do: {:error, :invalid_publication_authority}

  @doc "Authorizes all requested artifact destinations during phase 6."
  @spec authorize(binary(), keyword(), :normal | :private, :normal | :private_inspection) ::
          {:ok, t()} | {:error, authorization_error()}
  def authorize(run_ref, opts, event_policy, provider_class)
      when is_binary(run_ref) and is_list(opts) and event_policy in [:normal, :private] and
             provider_class in [:normal, :private_inspection] do
    with true <- valid_run_ref?(run_ref, true),
         true <- Keyword.keyword?(opts),
         private? <- event_policy == :private or provider_class == :private_inspection,
         trace_mode <- if(Keyword.has_key?(opts, :trace_dir), do: :exclusive, else: :append),
         :ok <- validate_option_keys(opts),
         {:ok, targets} <- targets(run_ref, opts, private?),
         :ok <- validate_result_class(private?, targets) do
      lifecycle = live_lifecycle()
      {:ok, claim_owner} = PublicationClaimOwner.start(lifecycle, self())

      case reserve_targets(run_ref, targets, private?, claim_owner, trace_mode) do
        {:ok, handles} ->
          authority = %__MODULE__{
            trace: handles[:trace],
            inspect: handles[:inspect],
            output: handles[:output],
            private_output: handles[:private_output],
            run_ref: run_ref,
            event_policy: event_policy,
            provider_class: provider_class,
            authorized?: true,
            attestation: <<>>,
            lifecycle: lifecycle,
            claim_owner: claim_owner
          }

          {:ok, attest(authority)}

        {:error, reason} ->
          _ = PublicationClaimOwner.terminalize(claim_owner)
          {:error, reason}
      end
    else
      false -> {:error, :invalid_destination}
      {:error, _reason} = error -> error
    end
  end

  def authorize(_run_ref, _opts, _event_policy, _provider_class),
    do: {:error, :invalid_destination}

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{attestation: attestation} = authority),
    do:
      fields_valid?(authority) and Attestation.valid?(__MODULE__, payload(authority), attestation)

  def valid?(_authority), do: false

  @doc false
  @spec authorized?(term()) :: boolean()
  def authorized?(%__MODULE__{authorized?: authorized?} = authority),
    do: valid?(authority) and authorized? and lifecycle_active?(authority.lifecycle)

  def authorized?(_authority), do: false

  @doc false
  @spec claim(t()) ::
          {:ok, PublicationClaimOwner.lease()} | {:error, :invalid_publication_authority}
  def claim(%__MODULE__{} = authority) do
    if valid?(authority) and authority.authorized? do
      case PublicationClaimOwner.claim(authority.claim_owner) do
        {:ok, lease} -> {:ok, lease}
        _error -> {:error, :invalid_publication_authority}
      end
    else
      {:error, :invalid_publication_authority}
    end
  rescue
    _exception -> {:error, :invalid_publication_authority}
  end

  def claim(_authority), do: {:error, :invalid_publication_authority}

  @doc false
  @spec claimed?(term()) :: boolean()
  def claimed?(%__MODULE__{} = authority),
    do:
      valid?(authority) and authority.authorized? and
        claim_owner_claimed?(authority.claim_owner)

  def claimed?(_authority), do: false

  @doc false
  @spec lease_valid?(term(), term()) :: boolean()
  def lease_valid?(%__MODULE__{} = authority, lease) do
    valid?(authority) and authority.authorized? and
      PublicationClaimOwner.valid?(authority.claim_owner, lease)
  rescue
    _exception -> false
  end

  def lease_valid?(_authority, _lease), do: false

  @doc false
  @spec matches_prepared?(term(), term()) :: boolean()
  def matches_prepared?(
        %__MODULE__{} = authority,
        %{effective_event_policy: event_policy, effective_data_class: provider_class}
      ) do
    authorized?(authority) and
      (unreserved?(authority) or
         (authority.event_policy == event_policy and authority.provider_class == provider_class))
  end

  def matches_prepared?(_authority, _prepared), do: false

  defp unreserved?(%__MODULE__{
         trace: nil,
         inspect: nil,
         output: nil,
         private_output: nil,
         run_ref: nil
       }),
       do: true

  defp unreserved?(_authority), do: false

  @doc false
  @spec options(t()) :: keyword()
  def options(%__MODULE__{} = authority) do
    if valid?(authority) do
      Enum.flat_map(@destination_keys, fn key ->
        case Map.fetch!(authority, key) do
          nil -> []
          _destination -> [{key, true}]
        end
      end)
      |> Enum.uniq()
    else
      raise ArgumentError, "invalid publication authority"
    end
  end

  @doc false
  @spec inspection_requested?(term()) :: boolean()
  def inspection_requested?(%__MODULE__{} = authority),
    do: authorized?(authority) and not is_nil(authority.inspect)

  def inspection_requested?(_authority), do: false

  @doc false
  @spec destination_options(t()) :: keyword()
  def destination_options(%__MODULE__{} = authority) do
    if valid?(authority) do
      Enum.flat_map(@destination_keys, fn key ->
        case Map.fetch!(authority, key) do
          nil -> []
          %{requested: path} -> [{:private_output, path}]
          %PublicationHandle{} = handle -> [{key, PublicationHandle.path(handle)}]
          path when is_binary(path) -> [{key, path}]
        end
      end)
      |> Enum.uniq()
    else
      raise ArgumentError, "invalid publication authority"
    end
  end

  @doc false
  @spec validate_distinct_destinations(keyword()) :: :ok | {:error, :conflicting_destinations}
  def validate_distinct_destinations(opts) when is_list(opts) do
    identities =
      opts
      |> Keyword.take(@destination_keys)
      |> Enum.map(fn {_key, path} -> path end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&DestinationIdentity.key/1)

    if length(identities) == MapSet.size(MapSet.new(identities)),
      do: :ok,
      else: {:error, :conflicting_destinations}
  end

  def validate_distinct_destinations(_opts), do: {:error, :conflicting_destinations}

  @doc false
  @spec handles(t()) :: %{optional(atom()) => PublicationHandle.t()}
  def handles(%__MODULE__{} = authority) do
    if authorized?(authority) do
      raw_handles(authority)
    else
      %{}
    end
  end

  @doc false
  @spec requested_result_handle(t()) :: PublicationHandle.t() | nil
  def requested_result_handle(%__MODULE__{} = authority) do
    case authority.private_output do
      %{requested_handle: %PublicationHandle{} = handle} -> handle
      _other -> nil
    end
  end

  @doc false
  @spec release_requested_result(t()) :: :ok | {:error, :publication_cleanup_failed}
  def release_requested_result(%__MODULE__{} = authority) do
    case requested_result_handle(authority) do
      nil ->
        :ok

      handle ->
        case PublicationHandle.release(handle) do
          :ok ->
            case PublicationClaimOwner.unregister(authority.claim_owner, handle) do
              :ok -> :ok
              {:error, _reason} -> {:error, :publication_cleanup_failed}
            end

          {:error, _reason} ->
            {:error, :publication_cleanup_failed}
        end
    end
  end

  @doc false
  @spec binding(term()) :: binary() | :invalid
  def binding(%__MODULE__{} = authority) do
    if valid?(authority), do: authority.attestation, else: :invalid
  end

  def binding(_authority), do: :invalid

  @doc false
  @spec matches?(term(), term()) :: boolean()
  def matches?(%__MODULE__{} = authority, binding),
    do: authorized?(authority) and Attestation.valid?(__MODULE__, payload(authority), binding)

  def matches?(_authority, _binding), do: false

  @doc false
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = authority) do
    terminalize(authority)
    :ok
  end

  def close(_authority), do: :ok

  @doc false
  @spec abort(t()) :: :ok | {:error, :publication_cleanup_failed}
  def abort(%__MODULE__{} = authority), do: terminalize(authority)

  def abort(_authority), do: :ok

  defp valid_option_keys?(opts), do: Keyword.keys(opts) -- @option_keys == []

  defp validate_option_keys(opts) do
    keys = Keyword.keys(opts)

    if valid_option_keys?(opts) and length(keys) == MapSet.size(MapSet.new(keys)),
      do: :ok,
      else: {:error, :invalid_destination}
  end

  defp unreserved(opts, lifecycle, claim_owner) do
    destinations? = Enum.any?(@destination_keys, &(not is_nil(Keyword.get(opts, &1))))

    %__MODULE__{
      trace: Keyword.get(opts, :trace),
      inspect: Keyword.get(opts, :inspect),
      output: Keyword.get(opts, :output),
      private_output: Keyword.get(opts, :private_output),
      run_ref: Keyword.get(opts, :run_ref),
      event_policy: :normal,
      provider_class: :normal,
      authorized?: not destinations?,
      attestation: <<>>,
      lifecycle: lifecycle,
      claim_owner: claim_owner
    }
  end

  defp validate_unreserved_options(opts) do
    destinations =
      Enum.all?(@destination_keys, fn key ->
        case Keyword.get(opts, key) do
          nil -> true
          path -> valid_path(path)
        end
      end)

    run_ref = Keyword.get(opts, :run_ref)

    if destinations and valid_run_ref?(run_ref, false),
      do: :ok,
      else: {:error, :invalid_publication_authority}
  end

  defp attest(authority),
    do: %{authority | attestation: Attestation.attest(__MODULE__, payload(authority))}

  defp fields_valid?(authority) do
    Enum.sort(Map.keys(authority)) == @field_keys and
      is_boolean(authority.authorized?) and
      authority.event_policy in [:normal, :private] and
      authority.provider_class in [:normal, :private_inspection] and
      valid_run_ref?(authority.run_ref, authority.authorized?) and
      valid_destination_value?(authority.trace, :trace, authority.authorized?) and
      valid_destination_value?(authority.inspect, :inspect, authority.authorized?) and
      valid_destination_value?(authority.output, :output, authority.authorized?) and
      valid_private_output?(authority.private_output, authority.authorized?) and
      is_reference(authority.lifecycle) and is_pid(authority.claim_owner)
  end

  defp valid_run_ref?(nil, false), do: true
  defp valid_run_ref?(nil, true), do: true

  defp valid_run_ref?(run_ref, _authorized?),
    do:
      is_binary(run_ref) and byte_size(run_ref) in 1..256 and String.valid?(run_ref) and
        not String.contains?(run_ref, <<0>>) and Path.basename(run_ref) == run_ref and
        run_ref not in [".", ".."]

  defp valid_destination_value?(nil, _kind, _authorized?), do: true
  defp valid_destination_value?(path, _kind, false), do: valid_path(path)

  defp valid_destination_value?(%PublicationHandle{kind: kind} = handle, key, true),
    do: PublicationHandle.valid?(handle) and kind == expected_kind(key)

  defp valid_destination_value?(_value, _kind, _authorized?), do: false

  defp expected_kind(:trace), do: :trace
  defp expected_kind(:inspect), do: :inspection
  defp expected_kind(:output), do: :result

  defp valid_private_output?(nil, _authorized?), do: true
  defp valid_private_output?(path, false) when is_binary(path), do: valid_path(path)

  defp valid_private_output?(
         %{
           requested: requested,
           requested_handle: %PublicationHandle{kind: :result} = requested_handle,
           recovery: %PublicationHandle{kind: :recovery} = recovery
         },
         true
       ),
       do:
         valid_path(requested) and
           PublicationHandle.valid?(requested_handle) and
           PublicationHandle.valid?(recovery)

  defp valid_private_output?(_value, _authorized?), do: false

  defp valid_path(path) when is_binary(path),
    do: String.valid?(path) and not String.contains?(path, <<0>>) and Path.type(path) == :absolute

  defp valid_path(_path), do: false

  defp payload(authority) do
    {
      authority.trace,
      authority.inspect,
      authority.output,
      authority.private_output,
      authority.run_ref,
      authority.event_policy,
      authority.provider_class,
      authority.authorized?,
      authority.lifecycle,
      authority.claim_owner
    }
  end

  defp live_lifecycle do
    lifecycle = :atomics.new(1, signed: false)
    :atomics.put(lifecycle, 1, 0)
    lifecycle
  end

  defp lifecycle_active?(lifecycle) do
    :atomics.get(lifecycle, 1) in [0, 1]
  rescue
    _exception -> false
  end

  defp claim_owner_claimed?(owner) do
    PublicationClaimOwner.claimed?(owner)
  rescue
    _exception -> false
  end

  defp terminalize(%__MODULE__{lifecycle: lifecycle, claim_owner: claim_owner}) do
    result =
      try do
        PublicationClaimOwner.terminalize(claim_owner)
      catch
        :exit, _reason -> :ok
      end

    :atomics.put(lifecycle, 1, 2)
    result
  rescue
    _exception -> :ok
  end

  defp raw_handles(%__MODULE__{} = authority) do
    if valid?(authority) do
      Enum.reduce(@destination_keys, %{}, fn key, acc ->
        case Map.fetch!(authority, key) do
          %PublicationHandle{} = handle ->
            Map.put(acc, key, handle)

          %{
            requested_handle: %PublicationHandle{} = requested_handle,
            recovery: %PublicationHandle{} = handle
          } ->
            acc
            |> Map.put(:result_reservation, requested_handle)
            |> Map.put(:recovery, handle)

          _missing ->
            acc
        end
      end)
    else
      %{}
    end
  end

  defp targets(run_ref, opts, private?) do
    trace = Keyword.get(opts, :trace)
    trace_dir = Keyword.get(opts, :trace_dir)

    cond do
      not is_nil(trace) and not is_nil(trace_dir) ->
        {:error, :conflicting_trace_destinations}

      not is_nil(Keyword.get(opts, :output)) and not is_nil(Keyword.get(opts, :private_output)) ->
        {:error, :conflicting_result_destinations}

      true ->
        with {:ok, trace} <- trace_target(run_ref, trace, trace_dir, private?),
             {:ok, inspect} <-
               tagged_destination(optional_path(Keyword.get(opts, :inspect)), :inspection),
             {:ok, output} <-
               tagged_destination(optional_path(Keyword.get(opts, :output)), :result),
             {:ok, private_output} <-
               tagged_destination(optional_path(Keyword.get(opts, :private_output)), :result),
             targets = %{
               trace: trace,
               inspect: inspect,
               output: output,
               private_output: private_output
             },
             :ok <- validate_target_paths(targets, private?),
             :ok <- validate_distinct_destinations(Map.to_list(targets)) do
          {:ok, targets}
        else
          {:error, _reason} = error -> error
        end
    end
  end

  defp trace_target(_run_ref, nil, nil, _private?), do: {:ok, nil}

  defp trace_target(_run_ref, path, nil, _private?),
    do: tagged_destination(optional_path(path), :trace)

  defp trace_target(run_ref, nil, trace_dir, private?) do
    with {:ok, directory} <- optional_path(trace_dir),
         {:ok, %{type: :directory}} <- File.stat(directory, time: :posix) do
      {:ok, Path.join(directory, run_ref <> trace_suffix(private?))}
    else
      {:error, :invalid_destination} -> {:error, {:invalid_destination, :trace}}
      {:error, _reason} -> {:error, {:destination_unavailable, :trace}}
      _other -> {:error, {:invalid_destination, :trace}}
    end
  end

  defp trace_target(_run_ref, _path, _trace_dir, _private?),
    do: {:error, {:invalid_destination, :trace}}

  defp trace_suffix(false), do: ".jsonl"
  defp trace_suffix(true), do: ".private.jsonl"

  defp optional_path(nil), do: {:ok, nil}

  defp optional_path(path) when is_binary(path) do
    case PrivateDirectory.anchor(path) do
      {:ok, path} -> if valid_path(path), do: {:ok, path}, else: {:error, :invalid_destination}
      _other -> {:error, :invalid_destination}
    end
  end

  defp optional_path(_path), do: {:error, :invalid_destination}

  defp validate_target_paths(%{trace: trace, inspect: inspect}, private?) do
    with :ok <- tagged_destination(validate_trace_path(trace, private?), :trace),
         do: tagged_destination(validate_inspection_path(inspect), :inspection)
  end

  defp validate_trace_path(nil, _private?), do: :ok

  defp validate_trace_path(path, private?),
    do: TraceLog.validate_append_path(path, private?)

  defp validate_inspection_path(nil), do: :ok
  defp validate_inspection_path(path), do: InspectionArtifact.validate_destination_path(path)

  defp validate_result_class(true, %{output: output}) when not is_nil(output),
    do: {:error, :private_destination_required}

  defp validate_result_class(_private?, _targets), do: :ok

  defp reserve_targets(run_ref, targets, private?, claim_owner, trace_mode) do
    case reserve_trace(targets.trace, private?, trace_mode, claim_owner) do
      {:ok, trace} ->
        case reserve_optional(targets.inspect, :inspection, 0o600, claim_owner) do
          {:ok, inspect} ->
            reserve_result_targets(run_ref, targets, trace, inspect, claim_owner, private?)

          {:error, reason} ->
            cleanup_reserved([trace])
            reservation_error(reason, :inspection)
        end

      {:error, reason} ->
        reservation_error(reason, :trace)
    end
  end

  defp reserve_result_targets(run_ref, targets, trace, inspect, claim_owner, private?) do
    case reserve_optional(targets.output, :result, if(private?, do: 0o600, else: 0), claim_owner) do
      {:ok, output} ->
        case reserve_private_result(run_ref, targets.private_output, claim_owner) do
          {:ok, private_output} ->
            {:ok,
             %{trace: trace, inspect: inspect, output: output, private_output: private_output}}

          {:error, reason} ->
            cleanup_reserved([trace, inspect, output])
            reservation_error(reason, :result)
        end

      {:error, reason} ->
        cleanup_reserved([trace, inspect])
        reservation_error(reason, :result)
    end
  end

  defp tagged_destination(:ok, _destination), do: :ok
  defp tagged_destination({:ok, value}, _destination), do: {:ok, value}

  defp tagged_destination({:error, reason}, destination),
    do: {:error, {reason, destination}}

  defp reservation_error(reason, _destination)
       when reason in [:destination_exists, :recovery_reservation_failed],
       do: {:error, reason}

  defp reservation_error(reason, destination), do: {:error, {reason, destination}}

  defp reserve_optional(nil, _kind, _mode, _claim_owner), do: {:ok, nil}

  defp reserve_optional(path, kind, mode, claim_owner) do
    case PublicationHandle.reserve_for(path, kind, mode, claim_owner) do
      {:ok, handle} -> register_handle(claim_owner, handle)
      {:error, :destination_exists} -> {:error, :destination_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve_trace(nil, _private?, _trace_mode, _claim_owner), do: {:ok, nil}

  defp reserve_trace(path, private?, :append, claim_owner) do
    mode = if(private?, do: 0o600, else: 0)

    case PublicationHandle.reserve_append_for(path, :trace, mode, claim_owner) do
      {:ok, handle} -> register_handle(claim_owner, handle)
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve_trace(path, private?, :exclusive, claim_owner) do
    reserve_optional(path, :trace, if(private?, do: 0o600, else: 0), claim_owner)
  end

  defp reserve_private_result(_run_ref, nil, _claim_owner), do: {:ok, nil}

  defp reserve_private_result(run_ref, requested, claim_owner) do
    recovery = Path.join(Path.dirname(requested), ".ptc-private-result-" <> run_ref <> ".json")

    case reserve_optional(requested, :result, 0o600, claim_owner) do
      {:ok, requested_handle} ->
        case PublicationHandle.reserve_visible_for(recovery, :recovery, 0o600, claim_owner) do
          {:ok, recovery_handle} ->
            register_private_recovery(
              requested,
              requested_handle,
              recovery,
              recovery_handle,
              claim_owner
            )

          {:error, _reason} ->
            cleanup_reserved([requested_handle])
            {:error, :recovery_reservation_failed}
        end

      {:error, :destination_exists} ->
        {:error, :destination_exists}

      {:error, _reason} ->
        {:error, :recovery_reservation_failed}
    end
  end

  defp register_private_recovery(
         requested,
         requested_handle,
         recovery,
         recovery_handle,
         claim_owner
       ) do
    if PublicationHandle.same_parent?(requested_handle, recovery) do
      register_private_recovery_handle(
        requested,
        requested_handle,
        recovery_handle,
        claim_owner
      )
    else
      _ = PublicationHandle.remove(recovery_handle)
      _ = PublicationHandle.close(recovery_handle)
      cleanup_reserved([requested_handle])
      {:error, :destination_exists}
    end
  end

  defp register_private_recovery_handle(
         requested,
         requested_handle,
         recovery_handle,
         claim_owner
       ) do
    case register_handle(claim_owner, recovery_handle) do
      {:ok, _recovery_handle} ->
        {:ok,
         %{
           requested: requested,
           requested_handle: requested_handle,
           recovery: recovery_handle
         }}

      {:error, _reason} = error ->
        _ = PublicationHandle.discard(recovery_handle)
        _ = PublicationHandle.close(recovery_handle)
        cleanup_reserved([requested_handle])
        error
    end
  end

  defp register_handle(claim_owner, handle) do
    case PublicationClaimOwner.register(claim_owner, handle) do
      :ok ->
        {:ok, handle}

      {:error, _reason} ->
        _ = PublicationHandle.discard(handle)
        _ = PublicationHandle.close(handle)
        {:error, :destination_unavailable}
    end
  end

  defp cleanup_reserved(handles) do
    handles
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn handle ->
      _ = PublicationHandle.remove(handle)
      PublicationHandle.close(handle)
    end)
  end
end
