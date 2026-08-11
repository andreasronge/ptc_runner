defmodule PtcRunner.Kernel.MCPOAuth.Authorization do
  @moduledoc """
  Callback-agnostic explicit MCP OAuth authorization operations.

  `begin_authorization/3` discovers and freezes the resource/server/client
  binding, creates one pending flow, and returns a one-time URL. Completion
  consumes state exactly once, takes the shared grant mutation lease, crosses
  the durable code-dispatch fence, exchanges the code once, and atomically
  installs the new grant. No operation opens a browser or runs during ordinary
  MCP execution.
  """

  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Binding
  alias PtcRunner.Kernel.MCPOAuth.Context
  alias PtcRunner.Kernel.MCPOAuth.Discovery
  alias PtcRunner.Kernel.MCPOAuth.PendingAuthorization
  alias PtcRunner.Kernel.MCPOAuth.Primitives
  alias PtcRunner.Kernel.MCPOAuth.Scope
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.TokenClient

  @recognized ~w(code error error_description error_uri iss state)
  @max_callback_parameters 32
  @max_callback_bytes 16_384

  @spec begin_authorization(Context.t(), Authority.t(), keyword()) ::
          {:ok, PendingAuthorization.t()} | {:error, atom()}
  def begin_authorization(%Context{} = context, %Authority{} = authority, opts)
      when is_list(opts) do
    with {:ok, authority_epoch} <- authority_epoch(context, authority, opts),
         key = Context.grant_key(context, authority, authority_epoch),
         deadline_ms = deadline(authority, opts),
         true <- deadline_ms > System.monotonic_time(:millisecond),
         redirect_uri when is_binary(redirect_uri) <- Keyword.get(opts, :redirect_uri),
         :ok <- validate_redirect(authority, redirect_uri),
         {:ok, freshness_anchor} <-
           Store.time_anchor(context.store, Deadline.from_expires_at(deadline_ms)),
         {:ok, binding} <-
           Discovery.discover(
             authority,
             discovery_options(opts, deadline_ms, redirect_uri)
           ),
         binding = Map.put(binding, :freshness_anchor, freshness_anchor),
         {:ok, current_grant} <-
           Store.load_grant(context.store, key, Deadline.from_expires_at(deadline_ms)),
         {:ok, requirement} <-
           Store.load_requirement(context.store, key, Deadline.from_expires_at(deadline_ms)),
         {:ok, requested_scopes, required_scopes, requirement_version} <-
           flow_scopes(binding, current_grant, requirement, authority),
         material = Primitives.new_flow(),
         {:ok, scope} <- Scope.serialize(requested_scopes),
         {:ok, url} <-
           Primitives.authorization_url(
             binding.authorization_server.authorization_endpoint,
             [
               {"response_type", "code"},
               {"client_id", authority.client.client_id},
               {"redirect_uri", redirect_uri},
               {"scope", scope},
               {"resource", authority.resource},
               {"code_challenge", material.challenge},
               {"code_challenge_method", "S256"},
               {"state", material.state}
             ],
             endpoint_options(authority)
           ),
         flow = %{
           state: material.state,
           verifier: material.verifier,
           issuer: authority.issuer,
           issuer_required?:
             binding.authorization_server.authorization_response_iss_parameter_supported,
           requested_scopes: requested_scopes,
           required_scopes: required_scopes,
           requirement_version: requirement_version,
           redirect_uri: redirect_uri,
           binding: binding
         },
         {:ok, stored} <-
           Store.begin_flow(
             context.store,
             key,
             flow,
             remaining(deadline_ms),
             Deadline.from_expires_at(deadline_ms)
           ) do
      {:ok,
       %PendingAuthorization{
         key: key,
         flow_id: stored.id,
         url: url,
         redirect_uri: redirect_uri,
         deadline_ms: deadline_ms,
         authority: authority,
         store: context.store
       }}
    else
      false -> {:error, :authorization_timeout}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_authorization}
    end
  end

  def begin_authorization(_context, _authority, _opts),
    do: {:error, :invalid_authorization}

  @spec complete_authorization(
          Context.t(),
          PendingAuthorization.t(),
          [{binary(), binary()}],
          keyword()
        ) :: {:ok, map()} | {:error, atom()}
  def complete_authorization(
        %Context{} = context,
        %PendingAuthorization{} = pending,
        parameters,
        opts
      )
      when is_list(parameters) and is_list(opts) do
    cond do
      not pending_context?(context, pending) ->
        {:error, :invalid_authorization_context}

      pending.deadline_ms > System.monotonic_time(:millisecond) ->
        with {:ok, callback} <- parse_callback(parameters) do
          complete_callback(context, pending, callback, opts)
        end

      true ->
        {:error, :authorization_timeout}
    end
  end

  def complete_authorization(_context, _pending, _parameters, _opts),
    do: {:error, :invalid_authorization}

  @doc """
  Cancels one pending authorization under a supplied terminal deadline.

  The `:cleanup_deadline` option is required and belongs to the lifecycle owner
  that installed the provider cleanup budget. Cancellation is terminal cleanup,
  so it is never charged whatever remained of the interaction it cleans up, and
  a caller must not treat an uncommitted cancellation as success.
  """
  @spec cancel_authorization(Context.t(), PendingAuthorization.t(), keyword()) ::
          :ok | {:error, atom()}
  def cancel_authorization(%Context{} = context, %PendingAuthorization{} = pending, opts) do
    # Cancellation is terminal cleanup, so its budget belongs to the lifecycle
    # owner that installed it and is anchored by the caller entering cleanup.
    # Charging it whatever remained of the interaction it is cleaning up gave an
    # expired interaction one millisecond and then discarded the outcome.
    with {:ok, deadline} <- terminal_deadline(opts),
         true <- pending_context?(context, pending) do
      Store.cancel_flow(context.store, pending.key, pending.flow_id, deadline)
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_authorization_context}
    end
  end

  def cancel_authorization(_context, _pending, _opts),
    do: {:error, :invalid_authorization}

  defp terminal_deadline(opts) when is_list(opts) do
    case Keyword.fetch(opts, :cleanup_deadline) do
      {:ok, deadline} ->
        if Deadline.valid?(deadline),
          do: {:ok, deadline},
          else: {:error, :invalid_authorization}

      :error ->
        {:error, :invalid_authorization}
    end
  end

  defp terminal_deadline(_opts), do: {:error, :invalid_authorization}

  defp complete_callback(
         context,
         pending,
         %{error: _error, state: state} = callback,
         _opts
       ) do
    case Store.deny_flow(
           context.store,
           pending.key,
           pending.flow_id,
           state,
           Map.get(callback, :issuer),
           Deadline.from_expires_at(pending.deadline_ms)
         ) do
      :ok -> {:error, :authorization_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_callback(context, pending, %{code: code, state: state} = callback, opts) do
    case Store.consume_callback(
           context.store,
           pending.key,
           pending.flow_id,
           state,
           Map.get(callback, :issuer),
           Deadline.from_expires_at(pending.deadline_ms)
         ) do
      {:ok, flow} ->
        complete_consumed_callback(context, pending, flow, code, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp complete_consumed_callback(context, pending, flow, code, opts) do
    case Store.acquire_mutation(
           context.store,
           pending.key,
           :authorization,
           remaining(pending.deadline_ms),
           Deadline.from_expires_at(pending.deadline_ms)
         ) do
      {:ok, lease} ->
        case current_binding(context, flow, pending, opts) do
          {:ok, binding} ->
            complete_with_lease(context, pending, flow, binding, lease, code, opts)

          {:error, _reason} = error ->
            fail_before_code_dispatch(context, pending, lease)
            error
        end

      {:error, _reason} = error ->
        cancel_consumed_flow(context, pending, Deadline.terminalization(pending.deadline_ms))
        error
    end
  end

  defp complete_with_lease(context, pending, flow, binding, lease, code, opts) do
    with true <- lease.starting_generation == flow.starting_generation,
         {:ok, anchor} <-
           Store.time_anchor(
             context.store,
             Deadline.from_expires_at(pending.deadline_ms)
           ) do
      token_result =
        TokenClient.exchange_code(
          pending.authority,
          Map.put(binding, :requested_scopes, flow.requested_scopes),
          %{code: code, verifier: flow.verifier, redirect_uri: pending.redirect_uri},
          token_options(context, opts, pending, binding, lease)
        )

      commit_authorization(
        context,
        pending,
        flow,
        binding,
        lease,
        anchor,
        token_result
      )
    else
      false ->
        fail_before_code_dispatch(context, pending, lease)
        {:error, :stale_authorization}

      {:error, _reason} = error ->
        fail_before_code_dispatch(context, pending, lease)
        error
    end
  end

  defp commit_authorization(
         context,
         pending,
         flow,
         binding,
         lease,
         anchor,
         {:ok, grant}
       ) do
    if MapSet.subset?(flow.required_scopes, grant.granted_scopes) do
      stored_grant =
        grant
        |> Map.delete(:ttl_ms)
        |> Map.put(:metadata_binding, Binding.identity(binding))
        |> Map.put(:metadata_revision, 1)
        |> Map.put(:redirect_uri, pending.redirect_uri)

      case Store.commit_grant(
             context.store,
             pending.key,
             lease.fence,
             stored_grant,
             grant.ttl_ms,
             anchor,
             Deadline.from_expires_at(pending.deadline_ms)
           ) do
        {:ok, _grant} = success ->
          success

        {:error, _reason} ->
          _ =
            Store.fail_mutation(
              context.store,
              pending.key,
              lease.fence,
              :possibly_dispatched,
              Deadline.terminalization(pending.deadline_ms)
            )

          {:error, :authorization_failed}
      end
    else
      _ =
        Store.fail_mutation(
          context.store,
          pending.key,
          lease.fence,
          :possibly_dispatched,
          Deadline.terminalization(pending.deadline_ms)
        )

      {:error, :mcp_authorization_required}
    end
  end

  defp commit_authorization(
         context,
         pending,
         _flow,
         _binding,
         lease,
         _anchor,
         {:error, reason, provenance}
       ) do
    outcome = if provenance == :not_dispatched, do: :not_dispatched, else: :possibly_dispatched

    _ =
      Store.fail_mutation(
        context.store,
        pending.key,
        lease.fence,
        outcome,
        Deadline.terminalization(pending.deadline_ms)
      )

    {:error, closed_token_error(reason)}
  end

  # One terminalization budget covers the whole cleanup: minting a second
  # deadline for the flow cancellation would let an unresponsive store
  # consume the floor twice for one terminal transition.
  defp fail_before_code_dispatch(context, pending, lease) do
    deadline = Deadline.terminalization(pending.deadline_ms)

    _ =
      Store.fail_mutation(
        context.store,
        pending.key,
        lease.fence,
        :not_dispatched,
        deadline
      )

    cancel_consumed_flow(context, pending, deadline)
  end

  defp cancel_consumed_flow(context, pending, deadline) do
    _ =
      Store.cancel_flow(
        context.store,
        pending.key,
        pending.flow_id,
        deadline
      )

    :ok
  end

  defp current_binding(
         _context,
         %{
           binding_freshness_remaining_ms: remaining,
           binding_freshness_fence: freshness_fence,
           binding: binding
         },
         _pending,
         _opts
       )
       when remaining > 0,
       do: {:ok, Map.put(binding, :freshness_fence, freshness_fence)}

  defp current_binding(context, %{binding: old_binding}, pending, opts) do
    with {:ok, freshness_anchor} <-
           Store.time_anchor(
             context.store,
             Deadline.from_expires_at(pending.deadline_ms)
           ),
         {:ok, new_binding} <-
           Discovery.discover(
             pending.authority,
             discovery_options(opts, pending.deadline_ms, pending.redirect_uri)
           ),
         true <- Binding.identity(old_binding) == Binding.identity(new_binding) do
      {:ok, Map.put(new_binding, :freshness_anchor, freshness_anchor)}
    else
      _stale_or_unavailable -> {:error, :stale_authorization_binding}
    end
  end

  defp flow_scopes(binding, current_grant, requirement, authority) do
    previous =
      case current_grant do
        %{requested_scopes: scopes} when is_struct(scopes, MapSet) -> scopes
        _absent -> MapSet.new()
      end

    required =
      case requirement do
        %{scopes: scopes} when is_struct(scopes, MapSet) ->
          MapSet.union(binding.required_scopes, scopes)

        _absent ->
          binding.required_scopes
      end

    requested =
      previous
      |> MapSet.union(binding.requested_scopes)
      |> MapSet.union(required)

    version = if requirement, do: requirement.version, else: 0

    if MapSet.size(requested) > 0 and MapSet.subset?(requested, authority.scope_ceiling),
      do: {:ok, requested, required, version},
      else: {:error, :mcp_authorization_required}
  end

  defp parse_callback(parameters)
       when length(parameters) <= @max_callback_parameters do
    with true <-
           Enum.all?(parameters, fn
             {name, value} when is_binary(name) and is_binary(value) ->
               byte_size(name) in 1..256 and byte_size(value) <= @max_callback_bytes and
                 String.valid?(name) and String.valid?(value)

             _invalid ->
               false
           end),
         recognized = Enum.filter(parameters, fn {name, _value} -> name in @recognized end),
         names = Enum.map(recognized, &elem(&1, 0)),
         true <- names == Enum.uniq(names),
         values = Map.new(recognized),
         state when is_binary(state) and state != "" <- Map.get(values, "state"),
         code = Map.get(values, "code"),
         error = Map.get(values, "error"),
         true <- valid_callback_shape?(code, error) do
      result = %{state: state}
      result = if code, do: Map.put(result, :code, code), else: result
      result = if error, do: Map.put(result, :error, error), else: result

      result =
        case Map.get(values, "iss") do
          nil -> result
          issuer -> Map.put(result, :issuer, issuer)
        end

      {:ok, result}
    else
      _invalid -> {:error, :invalid_callback}
    end
  end

  defp parse_callback(_parameters), do: {:error, :invalid_callback}

  defp valid_callback_shape?(code, nil), do: valid_callback_value?(code)
  defp valid_callback_shape?(nil, error), do: valid_callback_value?(error)
  defp valid_callback_shape?(_code, _error), do: false

  defp valid_callback_value?(value),
    do:
      is_binary(value) and byte_size(value) in 1..8_192 and String.valid?(value) and
        not String.contains?(value, ["\r", "\n", <<0>>])

  defp authority_epoch(context, authority, opts) do
    case Keyword.get(opts, :authority_epoch) do
      nil ->
        with {:ok, claims} <-
               Store.claim_authorities(
                 context.store,
                 context.tenant_id,
                 [{authority.installation_id, authority.fingerprint}],
                 Deadline.new(5_000)
               ) do
          {:ok, Map.fetch!(claims, authority.installation_id)}
        end

      epoch ->
        {:ok, epoch}
    end
  end

  defp validate_redirect(%Authority{client: %{redirect: {:https, redirects}}}, redirect_uri) do
    if redirect_uri in redirects, do: :ok, else: {:error, :invalid_redirect}
  end

  defp validate_redirect(
         %Authority{client: %{redirect: {:loopback, descriptor}}},
         redirect_uri
       ) do
    case URI.parse(redirect_uri) do
      %URI{
        scheme: "http",
        host: host,
        port: port,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when host == descriptor.host and path == descriptor.path and is_integer(port) and
             port in 1..65_535 ->
        :ok

      _invalid ->
        {:error, :invalid_redirect}
    end
  end

  defp pending_context?(context, pending) do
    expected_key =
      Context.grant_key(context, pending.authority, pending.key.authority_epoch)

    pending.store == context.store and expected_key == pending.key
  end

  defp token_options(context, opts, pending, binding, lease) do
    before_dispatch = fn ->
      with {:ok, dispatch_binding} <- binding_for_dispatch(binding) do
        Store.begin_code_dispatch(
          context.store,
          pending.key,
          pending.flow_id,
          lease.fence,
          dispatch_binding,
          Deadline.from_expires_at(pending.deadline_ms)
        )
      end
    end

    opts
    |> Keyword.take([:request, :resolver])
    |> Keyword.put(:credential_resolver, context.credential_resolver)
    |> Keyword.put(:deadline_ms, pending.deadline_ms)
    |> Keyword.put(:before_dispatch, before_dispatch)
  end

  defp discovery_options(opts, deadline_ms, redirect_uri) do
    opts
    |> Keyword.take([:request, :resolver])
    |> Keyword.put(:deadline_ms, deadline_ms)
    |> Keyword.put(:redirect_uri, redirect_uri)
  end

  defp deadline(authority, opts),
    do:
      Keyword.get(
        opts,
        :deadline_ms,
        System.monotonic_time(:millisecond) + authority.authorization_timeout_ms
      )

  defp binding_for_dispatch(%{freshness_fence: _fence} = binding), do: {:ok, binding}

  defp binding_for_dispatch(
         %{freshness_anchor: _anchor, freshness_anchor_ttl_ms: ttl_ms} = binding
       )
       when is_integer(ttl_ms) and ttl_ms >= 0,
       do: {:ok, binding}

  defp binding_for_dispatch(_binding), do: {:error, :stale_authorization_binding}

  defp endpoint_options(%Authority{issuer: issuer}) do
    case URI.parse(issuer) do
      %URI{scheme: "http", host: host} when host in ["127.0.0.1", "::1"] ->
        [allow_insecure_loopback: true]

      _secure ->
        []
    end
  end

  defp remaining(deadline_ms),
    do: max(deadline_ms - System.monotonic_time(:millisecond), 1)

  defp closed_token_error(:timeout), do: :authorization_timeout
  defp closed_token_error(:credential_resolution_failed), do: :credential_resolution_failed
  defp closed_token_error(_reason), do: :authorization_failed
end
