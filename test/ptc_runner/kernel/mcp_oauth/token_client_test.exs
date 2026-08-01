defmodule PtcRunner.Kernel.MCPOAuth.TokenClientTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.CredentialResolver
  alias PtcRunner.Kernel.MCPOAuth.Primitives
  alias PtcRunner.Kernel.MCPOAuth.TokenClient

  test "exchanges one public code with exact form headers and resource" do
    authority = authority(:none)
    material = Primitives.new_flow()
    parent = self()

    request = fn :post, url, headers, body, _timeout ->
      send(parent, {:token_request, url, headers, URI.decode_query(body)})

      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body:
           Jason.encode!(%{
             "access_token" => "access-token",
             "refresh_token" => "refresh-token",
             "token_type" => "Bearer",
             "expires_in" => 60,
             "scope" => "read"
           })
       }}
    end

    assert {:ok, grant} =
             TokenClient.exchange_code(
               authority,
               oauth_binding(authority),
               %{
                 code: "one use code",
                 verifier: material.verifier,
                 redirect_uri: "http://127.0.0.1:49152/callback"
               },
               request: request
             )

    assert grant.access_token == "access-token"
    assert grant.refresh_token == "refresh-token"
    assert grant.ttl_ms == 60_000

    assert_receive {:token_request, "https://auth.example/token", headers, form}
    assert {"content-type", "application/x-www-form-urlencoded"} in headers
    assert {"accept", "application/json"} in headers
    refute Enum.any?(headers, fn {name, _value} -> name == "authorization" end)
    assert form["grant_type"] == "authorization_code"
    assert form["resource"] == authority.resource
    assert form["client_id"] == authority.client.client_id
    assert form["code"] == "one use code"
    assert form["code_verifier"] == material.verifier
  end

  test "form-encodes a refresh token containing RFC 6749 VSCHAR spaces" do
    authority = authority(:none)
    parent = self()

    request = fn :post, _url, _headers, body, _timeout ->
      send(parent, {:refresh_form, URI.decode_query(body)})

      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body:
           Jason.encode!(%{
             "access_token" => "replacement",
             "refresh_token" => "next refresh token",
             "token_type" => "Bearer",
             "scope" => "read"
           })
       }}
    end

    grant = %{
      refresh_authorized: true,
      refresh_token: "old refresh token",
      granted_scopes: MapSet.new(["read"])
    }

    assert {:ok, %{refresh_token: "next refresh token"}} =
             TokenClient.refresh(authority, oauth_binding(authority), grant, request: request)

    assert_receive {:refresh_form, form}
    assert form["refresh_token"] == "old refresh token"
  end

  test "resolves and releases a confidential secret only around dispatch" do
    authority = authority(:client_secret_basic)
    material = Primitives.new_flow()
    parent = self()

    resolver = fn "oauth_secret", _deadline ->
      {:ok,
       %{
         value: "sëcret&",
         release: fn -> send(parent, :released) end
       }}
    end

    request = fn :post, _url, headers, _body, _timeout ->
      authorization = headers |> List.keyfind("authorization", 0) |> elem(1)
      send(parent, {:authorization, authorization})

      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body:
           Jason.encode!(%{
             "access_token" => "access",
             "token_type" => "Bearer",
             "scope" => "read"
           })
       }}
    end

    assert {:ok, _grant} =
             TokenClient.exchange_code(
               authority,
               oauth_binding(authority),
               %{
                 code: "code",
                 verifier: material.verifier,
                 redirect_uri: "https://app.example/callback"
               },
               credential_resolver: resolver,
               request: request
             )

    assert_receive {:authorization, "Basic " <> encoded}
    assert Base.decode64!(encoded) == "client:s%C3%ABcret%26"
    assert_receive :released
  end

  test "preserves transport dispatch provenance and closes provider errors" do
    authority = authority(:none)
    material = Primitives.new_flow()
    operation = %{code: "code", verifier: material.verifier, redirect_uri: "http://x"}

    assert {:error, :transport_error, :not_dispatched} =
             TokenClient.exchange_code(authority, oauth_binding(authority), operation,
               request: fn _, _, _, _, _ ->
                 {:error, :econnrefused, :not_dispatched}
               end
             )

    assert {:error, :invalid_grant, :possibly_dispatched} =
             TokenClient.exchange_code(authority, oauth_binding(authority), operation,
               request: fn _, _, _, _, _ ->
                 {:ok,
                  %{
                    status: 400,
                    headers: [{"content-type", "application/json"}],
                    body:
                      Jason.encode!(%{
                        "error" => "invalid_grant",
                        "error_description" => "secret provider detail"
                      })
                  }}
               end
             )
  end

  test "treats an exception after the durable dispatch fence as possibly dispatched" do
    authority = authority(:none)
    material = Primitives.new_flow()
    operation = %{code: "code", verifier: material.verifier, redirect_uri: "http://x"}

    assert {:error, :transport_error, :possibly_dispatched} =
             TokenClient.exchange_code(authority, oauth_binding(authority), operation,
               before_dispatch: fn -> :ok end,
               request: fn _, _, _, _, _ -> raise "socket ownership changed" end
             )
  end

  test "treats malformed response projection after the fence as possibly dispatched" do
    authority = authority(:none)
    material = Primitives.new_flow()
    operation = %{code: "code", verifier: material.verifier, redirect_uri: "http://x"}

    assert {:error, :transport_error, :possibly_dispatched} =
             TokenClient.exchange_code(authority, oauth_binding(authority), operation,
               before_dispatch: fn -> :ok end,
               request: fn _, _, _, _, _ -> {:ok, %{headers: [], body: ""}} end
             )
  end

  test "recomputes the remaining deadline after the durable dispatch fence" do
    authority = authority(:none)
    material = Primitives.new_flow()
    operation = %{code: "code", verifier: material.verifier, redirect_uri: "http://x"}
    deadline_ms = System.monotonic_time(:millisecond) + 10

    assert {:error, :timeout, :not_dispatched} =
             TokenClient.exchange_code(authority, oauth_binding(authority), operation,
               deadline_ms: deadline_ms,
               before_dispatch: fn ->
                 wait_until(deadline_ms)
                 :ok
               end,
               request: fn _, _, _, _, _ -> flunk("request started after its deadline") end
             )
  end

  test "bounds confidential resolver and release callbacks" do
    authority = authority(:client_secret_basic)
    material = Primitives.new_flow()
    operation = %{code: "code", verifier: material.verifier, redirect_uri: "http://x"}

    blocking_resolver = fn "oauth_secret", _deadline ->
      receive do
        :never -> {:ok, "secret"}
      end
    end

    assert {:error, :timeout, :not_dispatched} =
             TokenClient.exchange_code(authority, oauth_binding(authority), operation,
               deadline_ms: System.monotonic_time(:millisecond) + 20,
               credential_resolver: blocking_resolver,
               request: fn _, _, _, _, _ -> flunk("request ran without a resolved secret") end
             )

    parent = self()

    blocking_release = fn ->
      send(parent, :release_started)

      receive do
        :never -> :ok
      end
    end

    resolver = fn "oauth_secret", _deadline ->
      {:ok, %{value: "secret", release: blocking_release}}
    end

    release_deadline_ms = System.monotonic_time(:millisecond) + 10

    request = fn _, _, _, _, _ ->
      wait_until(release_deadline_ms)

      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body:
           Jason.encode!(%{
             "access_token" => "access",
             "token_type" => "Bearer",
             "scope" => "read"
           })
       }}
    end

    assert {:ok, _grant} =
             TokenClient.exchange_code(authority, oauth_binding(authority), operation,
               deadline_ms: release_deadline_ms,
               credential_resolver: resolver,
               request: request
             )

    assert_receive :release_started

    long_deadline_task =
      Task.async(fn ->
        TokenClient.exchange_code(authority, oauth_binding(authority), operation,
          deadline_ms: System.monotonic_time(:millisecond) + 60_000,
          credential_resolver: resolver,
          request: fn _, _, _, _, _ ->
            {:ok,
             %{
               status: 200,
               headers: [{"content-type", "application/json"}],
               body:
                 Jason.encode!(%{
                   "access_token" => "access",
                   "token_type" => "Bearer",
                   "scope" => "read"
                 })
             }}
          end
        )
      end)

    assert {:ok, {:ok, _grant}} = Task.yield(long_deadline_task, 500)
  end

  test "releases a structured secret handle even when its value is invalid" do
    authority = authority(:client_secret_basic)
    material = Primitives.new_flow()
    parent = self()

    resolver = fn "oauth_secret", _deadline ->
      {:ok, %{value: <<0>>, release: fn -> send(parent, :invalid_handle_released) end}}
    end

    assert {:error, :credential_resolution_failed, :not_dispatched} =
             TokenClient.exchange_code(
               authority,
               oauth_binding(authority),
               %{
                 code: "code",
                 verifier: material.verifier,
                 redirect_uri: "https://app.example/callback"
               },
               credential_resolver: resolver,
               request: fn _, _, _, _, _ -> flunk("invalid secret was dispatched") end
             )

    assert_receive :invalid_handle_released
  end

  test "stops a resolver at its deadline without dispatching a late secret" do
    parent = self()

    resolver = fn "oauth_secret", _deadline ->
      send(parent, {:resolver_started, self()})

      receive do
        :never -> {:ok, "too-late"}
      end
    end

    resolution =
      Task.async(fn ->
        CredentialResolver.with_secret(
          resolver,
          "oauth_secret",
          System.monotonic_time(:millisecond) + 1_000,
          fn _secret -> flunk("late secret was dispatched") end
        )
      end)

    assert_receive {:resolver_started, resolver_pid}, 1_000
    resolver_ref = Process.monitor(resolver_pid)
    assert {:error, :timeout} = Task.await(resolution, 2_000)
    assert_receive {:DOWN, ^resolver_ref, :process, ^resolver_pid, :killed}, 1_000
  end

  defp oauth_binding(authority) do
    %{
      authorization_server: %{
        token_endpoint: "https://auth.example/token"
      },
      requested_scopes: MapSet.new(["read"]),
      refresh_authorized: true,
      authority: authority
    }
  end

  defp authority(method) do
    client =
      case method do
        :none ->
          %{
            "registration" => "pre_registered",
            "client_id" => "client",
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code", "refresh_token"],
            "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
          }

        :client_secret_basic ->
          %{
            "registration" => "pre_registered",
            "client_id" => "client",
            "token_endpoint_auth_method" => "client_secret_basic",
            "client_secret_binding" => "oauth_secret",
            "grant_types" => ["authorization_code"],
            "redirect_uris" => ["https://app.example/callback"]
          }
      end

    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "test",
          "issuer" => "https://auth.example",
          "scope_ceiling" => ["read"],
          "default_scopes" => ["read"],
          "refresh_access" => "when_supported",
          "client" => client
        },
        "https://mcp.example/mcp",
        MapSet.new(["oauth_secret"])
      )

    authority
  end

  defp wait_until(deadline_ms) do
    if System.monotonic_time(:millisecond) < deadline_ms,
      do: wait_until(deadline_ms),
      else: :ok
  end
end
