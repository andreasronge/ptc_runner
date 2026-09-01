defmodule PtcRunner.Kernel.Materialize do
  @moduledoc """
  Shared candidate-gate and source-export implementation for `ptc materialize`.

  Candidate mode hashes authored bytes, publishes `{candidate.clj,
  descriptor.json}`, and re-acquires the application through that descriptor.
  Source-export mode writes the installed effective component bytes to one
  owner-only file without creating a descriptor. The two modes are mutually
  exclusive because a descriptor hashes the exact candidate beside it.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.CandidateArtifact
  alias PtcRunner.Kernel.CandidatePromotion
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.PrivateDirectory
  alias PtcRunner.Kernel.StrictJSON

  @max_result_bytes 1_048_576
  @max_source_bytes 1_048_576

  @type target :: %{binary() => binary()}
  @type opts :: keyword()
  @type published :: CandidateArtifact.published()
  @type report :: CandidatePromotion.report()
  @type result ::
          {:ok, {:source_out, binary()}}
          | {:ok, {:candidate, report(), published()}}
          | {:refused, report()}
          | {:error, term()}

  @doc """
  Runs one materialize invocation against an application manifest path.

  Project command callers pass the non-secret installed limits decoded from
  the project's host document when present; direct callers and hostless projects
  use installed defaults. Neither
  source-export nor candidate acquisition resolves credentials or starts a
  provider.

  `:source_out` writes interned installed effective bytes for one selected
  component to a new owner-only file (mode 0600). `:out` plus `:source` or
  `:from_result` publishes a gated `{candidate.clj, descriptor.json}` directory.
  The modes are exclusive because a descriptor hashes the exact candidate
  published beside it.

  Candidate mode keeps the existing 1_048_576-byte replacement bound.
  `--source-out` writes interned acquired package bytes for the selected
  occurrence without compiling a bundle or assembling an environment. Those
  installed bytes can already exceed the candidate bound; submitting them as a
  replacement is refused with the existing too-large diagnostic.
  """
  @spec run(binary(), opts()) :: result()
  def run(application, opts) when is_binary(application) and is_list(opts) do
    with {:ok, mode} <- mode(opts),
         {:ok, component_id} <- required(opts, :component),
         {:ok, target} <- target(opts) do
      case mode do
        :source_out -> export_source(application, target, component_id, opts)
        :candidate -> materialize_candidate(application, target, component_id, opts)
      end
    end
  end

  def run(_application, _opts), do: {:error, :invalid_application_source}

  defp mode(opts) do
    source_out = Keyword.get(opts, :source_out)
    out = Keyword.get(opts, :out)

    cond do
      is_binary(source_out) and source_out_conflict?(opts) ->
        {:error, :conflicting_materialize_mode}

      is_binary(source_out) ->
        {:ok, :source_out}

      is_binary(out) ->
        {:ok, :candidate}

      true ->
        {:error, :missing_materialize_destination}
    end
  end

  defp source_out_conflict?(opts) do
    Enum.any?(
      [
        :out,
        :source,
        :from_result,
        :result_pointer,
        :origin_run_id,
        :origin_prompt_hash,
        :origin_authored_at
      ],
      fn key -> is_binary(Keyword.get(opts, key)) end
    ) or Keyword.has_key?(opts, :accept_widened_effect)
  end

  defp export_source(application, target, component_id, opts) do
    with {:ok, path} <- required(opts, :source_out),
         {:ok, fault_hook} <- optional_fault_hook(opts),
         {:ok, package} <- acquire_export(application, opts),
         {:ok, source} <- installed_source(package, target, component_id),
         {:ok, written} <- publish_source_out(path, source, fault_hook) do
      {:ok, {:source_out, written}}
    end
  end

  defp materialize_candidate(application, target, component_id, opts) do
    with {:ok, out} <- required(opts, :out),
         {:ok, source} <- candidate_source(opts),
         {:ok, base} <- acquire_candidate(application, opts, []),
         {:ok, base_source} <- installed_source(base, target, component_id),
         {:ok, published} <-
           CandidateArtifact.publish(
             out,
             source,
             descriptor(target, component_id, base_source, opts)
           ),
         {:ok, candidate} <- gate_acquire(application, published, opts),
         report <- evaluate(base, candidate, opts) do
      finish(report, published)
    end
  end

  defp finish(%{outcome: :pass} = report, published), do: {:ok, {:candidate, report, published}}

  defp finish(report, published) do
    case CandidateArtifact.discard(published) do
      :ok -> {:refused, report}
      {:error, :candidate_cleanup_failed} -> {:error, :candidate_cleanup_failed}
    end
  end

  defp evaluate(base, candidate, opts) do
    CandidatePromotion.evaluate(base, candidate,
      accept_widened_effect: Keyword.get(opts, :accept_widened_effect, false)
    )
  end

  defp gate_acquire(application, published, opts) do
    case acquire_candidate(application, opts, component_override_descriptor: published.descriptor) do
      {:ok, package} ->
        {:ok, package}

      {:error, reason} ->
        case CandidateArtifact.discard(published) do
          :ok -> {:error, reason}
          {:error, :candidate_cleanup_failed} -> {:error, :candidate_cleanup_failed}
        end
    end
  end

  defp acquire_export(application, opts) do
    case ApplicationPackage.acquire_directory(application,
           omit_input: true,
           installed_limits: Keyword.get(opts, :installed_limits, Limits.installed_defaults())
         ) do
      {:ok, package, _input} -> {:ok, package}
      {:error, reason} -> {:error, reason}
    end
  end

  defp acquire_candidate(application, materialize_opts, acquisition_opts) do
    case ApplicationPackage.request_directory(
           application,
           [
             result_projection: :native,
             installed_limits:
               Keyword.get(materialize_opts, :installed_limits, Limits.installed_defaults())
           ] ++ acquisition_opts
         ) do
      {:ok, request} -> {:ok, request.package}
      {:error, reason} -> {:error, reason}
    end
  end

  defp descriptor(target, component_id, base_source, opts) do
    %{
      "target" => target,
      "component_id" => component_id,
      "base_source_hash" => ComponentOverride.hash(base_source)
    }
    |> maybe_put_provenance(opts)
  end

  defp maybe_put_provenance(descriptor, opts) do
    provenance =
      %{}
      |> put_present("run_id", Keyword.get(opts, :origin_run_id))
      |> put_present("prompt_hash", Keyword.get(opts, :origin_prompt_hash))
      |> put_present("authored_at", Keyword.get(opts, :origin_authored_at))
      |> put_acceptance(Keyword.get(opts, :accept_widened_effect, false))

    if provenance == %{},
      do: descriptor,
      else: Map.put(descriptor, "provenance", provenance)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_acceptance(map, false), do: map
  defp put_acceptance(map, true), do: Map.put(map, "accept_widened_effect", true)

  defp installed_source(package, %{"environment" => "workflow"}, component_id) do
    case CandidatePromotion.component_source(package, "workflow", component_id) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, :override_component_not_selected}
    end
  end

  defp installed_source(package, %{"environment" => "mission", "mission" => name}, component_id) do
    case CandidatePromotion.component_source(package, {:mission, name}, component_id) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, :override_component_not_selected}
    end
  end

  defp target(opts) do
    workflow? = Keyword.has_key?(opts, :workflow)
    mission = Keyword.get(opts, :target_mission)

    cond do
      workflow? and is_binary(mission) ->
        {:error, :invalid_override_target}

      workflow? and Keyword.get(opts, :workflow) == true ->
        {:ok, %{"environment" => "workflow"}}

      not workflow? and is_binary(mission) ->
        {:ok, %{"environment" => "mission", "mission" => mission}}

      true ->
        {:error, :invalid_override_target}
    end
  end

  defp candidate_source(opts) do
    case {Keyword.get(opts, :source), Keyword.get(opts, :from_result)} do
      {nil, nil} ->
        {:error, :missing_candidate_source}

      {source, nil} ->
        read_bounded_source(
          source,
          @max_source_bytes,
          :candidate_source_too_large,
          :unreadable_candidate_source
        )

      {nil, result} ->
        extract_source(result, Keyword.get(opts, :result_pointer))

      {_source, _result} ->
        {:error, :conflicting_candidate_source}
    end
  end

  defp read_bounded_source(path, limit, too_large, unreadable) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          case IO.binread(device, limit + 1) do
            data when is_binary(data) and byte_size(data) > limit -> {:error, too_large}
            data when is_binary(data) -> {:ok, data}
            :eof -> {:ok, ""}
            _other -> {:error, unreadable}
          end
        after
          File.close(device)
        end

      {:error, _reason} ->
        {:error, unreadable}
    end
  end

  defp extract_source(_path, nil), do: {:error, :missing_result_pointer}

  defp extract_source(path, pointer) do
    with {:ok, raw} <- read_bounded(path),
         {:ok, decoded} <- decode_result(raw),
         {:ok, segments} <- pointer_segments(pointer),
         {:ok, value} <- resolve(decoded, segments) do
      if is_binary(value), do: {:ok, value}, else: {:error, :result_pointer_not_a_string}
    end
  end

  defp decode_result(raw) do
    case StrictJSON.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :result_artifact_invalid}
    end
  end

  defp read_bounded(path) do
    read_bounded_source(
      path,
      @max_result_bytes,
      :result_artifact_too_large,
      :unreadable_result_artifact
    )
  end

  defp pointer_segments(""), do: {:ok, []}

  defp pointer_segments("/" <> rest) do
    rest
    |> String.split("/")
    |> Enum.reduce_while({:ok, []}, fn token, {:ok, acc} ->
      case unescape_pointer_token(token) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        :error -> {:halt, {:error, :invalid_result_pointer}}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      {:error, _reason} = error -> error
    end
  end

  defp pointer_segments(_pointer), do: {:error, :invalid_result_pointer}

  defp unescape_pointer_token(token), do: unescape_pointer_token(token, [])

  defp unescape_pointer_token(<<>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp unescape_pointer_token(<<?~, ?0, rest::binary>>, acc),
    do: unescape_pointer_token(rest, [?~ | acc])

  defp unescape_pointer_token(<<?~, ?1, rest::binary>>, acc),
    do: unescape_pointer_token(rest, [?/ | acc])

  defp unescape_pointer_token(<<?~, _rest::binary>>, _acc), do: :error

  defp unescape_pointer_token(<<char, rest::binary>>, acc),
    do: unescape_pointer_token(rest, [char | acc])

  defp resolve(value, []), do: {:ok, value}

  defp resolve(value, [segment | rest]) when is_map(value) do
    case Map.fetch(value, segment) do
      {:ok, child} -> resolve(child, rest)
      :error -> {:error, :result_pointer_missing}
    end
  end

  defp resolve(value, [segment | rest]) when is_list(value) do
    case array_index(segment) do
      {:ok, index} ->
        case Enum.fetch(value, index) do
          {:ok, child} -> resolve(child, rest)
          :error -> {:error, :result_pointer_missing}
        end

      :error ->
        {:error, :invalid_result_pointer}
    end
  end

  defp resolve(_value, _segments), do: {:error, :result_pointer_missing}

  defp array_index("0"), do: {:ok, 0}

  defp array_index(<<first, _rest::binary>> = segment)
       when first in ?1..?9 do
    case Integer.parse(segment) do
      {index, ""} -> {:ok, index}
      _other -> :error
    end
  end

  defp array_index(_segment), do: :error

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_option, key}}
      value -> {:ok, value}
    end
  end

  defp optional_fault_hook(opts) do
    case Keyword.get(opts, :fault_hook) do
      nil -> {:ok, nil}
      hook when is_function(hook, 1) -> {:ok, hook}
      _other -> {:error, :source_out_failed}
    end
  end

  defp publish_source_out(path, source, fault_hook)
       when is_binary(path) and is_binary(source) and
              (is_nil(fault_hook) or is_function(fault_hook, 1)) do
    with {:ok, anchored} <- PrivateDirectory.anchor(path),
         :ok <- PrivateDirectory.preflight_writable_parent(anchored),
         :ok <- refuse_existing(anchored),
         :ok <- publish_staged(anchored, source, fault_hook) do
      {:ok, anchored}
    else
      {:error, :private_directory_parent_unavailable} ->
        {:error, :source_out_parent_unusable}

      {:error, :private_directory_parent_unsafe} ->
        {:error, :source_out_parent_unusable}

      {:error, :private_directory_unavailable} ->
        {:error, :source_out_parent_unusable}

      {:error, :private_directory_unsupported} ->
        {:error, :source_out_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_source_out(_path, _source, _fault_hook), do: {:error, :source_out_failed}

  defp refuse_existing(path) do
    case File.lstat(path) do
      {:ok, _stat} -> {:error, :source_out_destination_exists}
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :source_out_failed}
    end
  end

  defp publish_staged(path, source, fault_hook) do
    {temporary_directory, temporary} = PrivateDirectory.temporary_sibling(path, "source")

    case PrivateDirectory.create(temporary_directory) do
      :ok -> persist_staged(path, temporary_directory, temporary, source, fault_hook)
      {:error, :private_directory_parent_unavailable} -> {:error, :source_out_parent_unusable}
      {:error, :private_directory_parent_unsafe} -> {:error, :source_out_parent_unusable}
      {:error, :private_directory_unavailable} -> {:error, :source_out_parent_unusable}
      {:error, _reason} -> {:error, :source_out_failed}
    end
  end

  defp persist_staged(path, temporary_directory, temporary, source, fault_hook) do
    result =
      with :ok <- write_private(temporary, source),
           :ok <- File.ln(temporary, path) do
        :ok
      else
        {:error, :eexist} -> {:error, :source_out_destination_exists}
        {:error, _reason} -> {:error, :source_out_failed}
      end

    if result == :ok, do: after_link(fault_hook, temporary_directory)

    case {result, cleanup_staging(temporary, temporary_directory)} do
      {:ok, :ok} ->
        :ok

      {:ok, :error} ->
        {:error, :source_out_cleanup_failed}

      {{:error, reason}, _cleanup} ->
        {:error, reason}
    end
  end

  defp after_link(nil, _directory), do: :ok

  defp after_link(hook, directory) when is_function(hook, 1) do
    _ = hook.({:after_link, directory})
    :ok
  end

  defp cleanup_staging(temporary, temporary_directory) do
    with :ok <- unlink_if_present(temporary),
         :ok <- rmdir_if_present(temporary_directory) do
      :ok
    else
      _failed -> :error
    end
  end

  defp unlink_if_present(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp rmdir_if_present(path) do
    case File.rmdir(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :error
    end
  end

  # Restriction happens inside a newly created 0700 sibling, before any content
  # is written. The destination name appears only as a hard link of that inode.
  defp write_private(path, content) do
    result =
      File.open(path, [:write, :binary, :exclusive], fn device ->
        with :ok <- File.chmod(path, 0o600) do
          IO.binwrite(device, content)
        end
      end)

    case result do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, _reason}} ->
        _ = File.rm(path)
        {:error, :source_out_failed}

      {:error, :eexist} ->
        {:error, :source_out_destination_exists}

      {:error, _reason} ->
        {:error, :source_out_failed}

      _unexpected ->
        _ = File.rm(path)
        {:error, :source_out_failed}
    end
  end
end
