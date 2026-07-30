defmodule PtcRunner.Kernel.MCPOAuth.TokenClient do
  @moduledoc """
  One-shot authorization-code and refresh token endpoint client.

  Requests are form encoded, carry the exact resource indicator, never retry,
  and return explicit dispatch provenance. Provider bodies and authentication
  response headers are projected to closed results before returning.
  """

  alias PtcRunner.Kernel.MCPHTTPAdapter
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.CredentialResolver
  alias PtcRunner.Kernel.MCPOAuth.NetworkPolicy
  alias PtcRunner.Kernel.MCPOAuth.Primitives
  alias PtcRunner.Kernel.MCPOAuth.Scope
  alias PtcRunner.Kernel.MCPOAuth.TokenResponse

  @max_token_response_bytes 65_536

  @type provenance :: :not_dispatched | :possibly_dispatched

  @spec exchange_code(Authority.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, atom(), provenance()}
  def exchange_code(%Authority{} = authority, binding, operation, opts)
      when is_map(binding) and is_map(operation) and is_list(opts) do
    with code when is_binary(code) <- Map.get(operation, :code),
         true <- valid_opaque_code?(code),
         verifier when is_binary(verifier) <- Map.get(operation, :verifier),
         true <- Primitives.valid_verifier?(verifier),
         redirect_uri when is_binary(redirect_uri) <- Map.get(operation, :redirect_uri),
         %MapSet{} = requested_scopes <- Map.get(binding, :requested_scopes),
         {:ok, scope} <- Scope.serialize(requested_scopes) do
      parameters = [
        {"grant_type", "authorization_code"},
        {"code", code},
        {"redirect_uri", redirect_uri},
        {"code_verifier", verifier},
        {"client_id", authority.client.client_id},
        {"resource", authority.resource},
        {"scope", scope}
      ]

      token_request(authority, binding, parameters, opts)
    else
      _invalid -> {:error, :invalid_token_request, :not_dispatched}
    end
  end

  def exchange_code(_authority, _binding, _operation, _opts),
    do: {:error, :invalid_token_request, :not_dispatched}

  @spec refresh(Authority.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, atom(), provenance()}
  def refresh(%Authority{} = authority, binding, grant, opts)
      when is_map(binding) and is_map(grant) and is_list(opts) do
    with true <- Map.get(grant, :refresh_authorized) == true,
         refresh_token when is_binary(refresh_token) <- Map.get(grant, :refresh_token),
         {:ok, _refresh_token} <- TokenResponse.refresh_token(refresh_token),
         %MapSet{} = granted_scopes <- Map.get(grant, :granted_scopes),
         {:ok, scope} <- Scope.serialize(granted_scopes) do
      parameters = [
        {"grant_type", "refresh_token"},
        {"refresh_token", refresh_token},
        {"client_id", authority.client.client_id},
        {"resource", authority.resource},
        {"scope", scope}
      ]

      token_request(
        authority,
        Map.put(binding, :requested_scopes, granted_scopes),
        parameters,
        opts
      )
    else
      _invalid -> {:error, :authorization_required, :not_dispatched}
    end
  end

  def refresh(_authority, _binding, _grant, _opts),
    do: {:error, :invalid_token_request, :not_dispatched}

  defp token_request(authority, binding, parameters, opts) do
    deadline_ms =
      Keyword.get(
        opts,
        :deadline_ms,
        System.monotonic_time(:millisecond) + authority.authorization_timeout_ms
      )

    method = authority.client.token_endpoint_auth_method

    case method do
      :none ->
        safe_dispatch_token_request(authority, binding, parameters, nil, deadline_ms, opts)

      :client_secret_basic ->
        CredentialResolver.with_secret(
          Keyword.fetch!(opts, :credential_resolver),
          authority.client.client_secret_binding,
          deadline_ms,
          fn secret ->
            case Primitives.client_secret_basic(authority.client.client_id, secret) do
              {:ok, authorization} ->
                safe_dispatch_token_request(
                  authority,
                  binding,
                  parameters,
                  authorization,
                  deadline_ms,
                  opts
                )

              _invalid ->
                {:error, :credential_resolution_failed, :not_dispatched}
            end
          end
        )
        |> normalize_credential_result()
    end
  rescue
    _exception -> {:error, :credential_resolution_failed, :not_dispatched}
  catch
    _kind, _reason -> {:error, :credential_resolution_failed, :not_dispatched}
  end

  defp safe_dispatch_token_request(
         authority,
         binding,
         parameters,
         authorization,
         deadline_ms,
         opts
       ) do
    dispatch_token_request(authority, binding, parameters, authorization, deadline_ms, opts)
  rescue
    _exception -> {:error, :transport_error, :possibly_dispatched}
  catch
    _kind, _reason -> {:error, :transport_error, :possibly_dispatched}
  end

  defp dispatch_token_request(
         authority,
         binding,
         parameters,
         authorization,
         deadline_ms,
         opts
       ) do
    token_endpoint = binding.authorization_server.token_endpoint

    with remaining when remaining > 0 <- remaining(deadline_ms),
         {:ok, token_endpoint} <-
           Primitives.token_endpoint(token_endpoint, endpoint_options(authority)),
         {:ok, body} <- Primitives.form_encode(parameters),
         headers =
           [
             {"accept", "application/json"},
             {"content-type", "application/x-www-form-urlencoded"}
           ]
           |> maybe_authorization(authorization),
         :ok <- before_dispatch(opts),
         remaining when remaining > 0 <- remaining(deadline_ms),
         response <-
           request(
             authority,
             token_endpoint,
             headers,
             body,
             deadline_ms,
             opts
           ) do
      project_response(response, binding, authority)
    else
      remaining when is_integer(remaining) and remaining <= 0 ->
        {:error, :timeout, :not_dispatched}

      {:error, _reason} ->
        {:error, :dispatch_refused, :not_dispatched}

      _invalid ->
        {:error, :invalid_token_request, :not_dispatched}
    end
  end

  defp request(authority, url, headers, body, deadline_ms, opts) do
    remaining_ms = remaining(deadline_ms)

    if remaining_ms <= 0 do
      {:error, :timeout, :not_dispatched}
    else
      request_with_remaining(authority, url, headers, body, remaining_ms, deadline_ms, opts)
    end
  rescue
    _exception -> {:error, :transport_error, :possibly_dispatched}
  catch
    _kind, _reason -> {:error, :transport_error, :possibly_dispatched}
  end

  defp request_with_remaining(authority, url, headers, body, remaining_ms, deadline_ms, opts) do
    case Keyword.get(opts, :request) do
      function when is_function(function, 5) ->
        normalize_request_result(function.(:post, url, headers, body, remaining_ms))

      nil ->
        network_request(authority, url, headers, body, deadline_ms, opts)

      _invalid ->
        {:error, :transport_error, :not_dispatched}
    end
  end

  defp network_request(authority, url, headers, body, deadline_ms, opts) do
    resolver_opts =
      [deadline_ms: deadline_ms]
      |> then(fn resolver_opts ->
        case Keyword.get(opts, :resolver) do
          nil -> resolver_opts
          resolver -> [{:resolver, resolver} | resolver_opts]
        end
      end)

    with {:ok, target} <- NetworkPolicy.resolve(url, authority, resolver_opts),
         remaining_ms when remaining_ms > 0 <-
           deadline_ms - System.monotonic_time(:millisecond) do
      MCPHTTPAdapter.request(
        method: :post,
        url: url,
        headers: headers,
        body: body,
        timeout_ms: remaining_ms,
        max_body_bytes: @max_token_response_bytes,
        address: hd(target.addresses),
        connected_peer: NetworkPolicy.peer_verifier(target.addresses)
      )
    else
      remaining_ms when is_integer(remaining_ms) and remaining_ms <= 0 ->
        {:error, :timeout, :not_dispatched}

      _denied ->
        {:error, :transport_error, :not_dispatched}
    end
  end

  defp before_dispatch(opts) do
    case Keyword.get(opts, :before_dispatch, fn -> :ok end) do
      callback when is_function(callback, 0) ->
        case callback.() do
          :ok -> :ok
          _refused -> {:error, :dispatch_refused}
        end

      _invalid ->
        {:error, :dispatch_refused}
    end
  rescue
    _exception -> {:error, :dispatch_refused}
  catch
    _kind, _reason -> {:error, :dispatch_refused}
  end

  defp normalize_request_result({:ok, response}), do: {:ok, response}

  defp normalize_request_result({:error, reason, provenance})
       when provenance in [:not_dispatched, :possibly_dispatched],
       do: {:error, reason, provenance}

  defp normalize_request_result({:error, reason}),
    do: {:error, reason, :possibly_dispatched}

  defp normalize_request_result(_invalid),
    do: {:error, :transport_error, :possibly_dispatched}

  defp project_response({:ok, response}, binding, authority) do
    requested = binding.requested_scopes

    case TokenResponse.success(response.status, response.headers, response.body,
           requested_scopes: requested,
           refresh_authorized: binding.refresh_authorized
         ) do
      {:ok, grant} ->
        ttl_ms = grant.expires_in_ms || authority.unknown_expiry_ttl_ms

        {:ok,
         grant
         |> Map.delete(:expires_in_ms)
         |> Map.put(:requested_scopes, requested)
         |> Map.put(:refresh_authorized, binding.refresh_authorized)
         |> Map.put(:ttl_ms, ttl_ms)}

      {:error, :invalid_token_response} ->
        case TokenResponse.error(response.status, response.headers, response.body) do
          {:ok, "invalid_grant"} ->
            {:error, :invalid_grant, :possibly_dispatched}

          {:ok, _closed_error} ->
            {:error, :token_endpoint_error, :possibly_dispatched}

          {:error, :invalid_token_response} ->
            {:error, :invalid_token_response, :possibly_dispatched}
        end
    end
  end

  defp project_response({:error, reason, provenance}, _binding, _authority),
    do: {:error, closed_reason(reason), provenance}

  defp maybe_authorization(headers, nil), do: headers
  defp maybe_authorization(headers, value), do: [{"authorization", value} | headers]

  defp normalize_credential_result({:error, :timeout}),
    do: {:error, :timeout, :not_dispatched}

  defp normalize_credential_result({:error, :credential_resolution_failed}),
    do: {:error, :credential_resolution_failed, :not_dispatched}

  defp normalize_credential_result({:ok, _grant} = success), do: success
  defp normalize_credential_result({:error, _reason, _provenance} = error), do: error

  defp normalize_credential_result(_invalid),
    do: {:error, :credential_resolution_failed, :not_dispatched}

  defp remaining(deadline_ms),
    do: deadline_ms - System.monotonic_time(:millisecond)

  defp closed_reason(:timeout), do: :timeout
  defp closed_reason(_reason), do: :transport_error

  defp endpoint_options(%Authority{issuer: issuer}) do
    case URI.parse(issuer) do
      %URI{scheme: "http", host: host} when host in ["127.0.0.1", "::1"] ->
        [allow_insecure_loopback: true]

      _secure ->
        []
    end
  end

  defp valid_opaque_code?(value),
    do:
      byte_size(value) in 1..8_192 and
        Enum.all?(:binary.bin_to_list(value), &(&1 in 0x20..0x7E))
end
