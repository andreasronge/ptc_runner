defmodule PtcRunner.Kernel.MCPOAuth.Context do
  @moduledoc """
  Principal-scoped host authorization context.

  Hosts construct a context from already authenticated tenant/principal
  identity. No MCP response, manifest, process dictionary, or application
  environment may supply these values. Construction atomically claims the
  principal lifecycle epoch from the configured store.
  """

  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.GrantKey
  alias PtcRunner.Kernel.MCPOAuth.Store

  @enforce_keys [
    :tenant_id,
    :principal_id,
    :principal_epoch,
    :store,
    :interaction,
    :credential_resolver
  ]
  defstruct @enforce_keys

  @type credential_resolver ::
          (binary(), integer() -> {:ok, term()} | {:error, atom()})
  @type interaction :: module() | nil

  @type t :: %__MODULE__{
          tenant_id: binary(),
          principal_id: binary(),
          principal_epoch: term(),
          store: Store.t(),
          interaction: interaction(),
          credential_resolver: credential_resolver()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, atom()}
  def new(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <-
           keys -- [:tenant_id, :principal_id, :store, :interaction, :credential_resolver] ==
             [] and Enum.uniq(keys) == keys,
         tenant_id when is_binary(tenant_id) <- Keyword.get(opts, :tenant_id),
         true <- bounded_id?(tenant_id),
         principal_id when is_binary(principal_id) <- Keyword.get(opts, :principal_id),
         true <- bounded_id?(principal_id),
         {_module, _state} = store <- Keyword.get(opts, :store),
         interaction <- Keyword.get(opts, :interaction),
         true <- is_nil(interaction) or is_atom(interaction),
         resolver when is_function(resolver, 2) <-
           Keyword.get(opts, :credential_resolver, &missing_credential/2),
         {:ok, principal_epoch} <-
           Store.claim_principal(store, tenant_id, principal_id, 5_000) do
      {:ok,
       %__MODULE__{
         tenant_id: tenant_id,
         principal_id: principal_id,
         principal_epoch: principal_epoch,
         store: store,
         interaction: interaction,
         credential_resolver: resolver
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_authorization_context}
    end
  end

  def new(_opts), do: {:error, :invalid_authorization_context}

  @spec grant_key(t(), Authority.t(), term()) :: GrantKey.t()
  def grant_key(%__MODULE__{} = context, %Authority{} = authority, authority_epoch) do
    struct!(GrantKey,
      tenant_id: context.tenant_id,
      principal_id: context.principal_id,
      installation_id: authority.installation_id,
      resource: authority.resource,
      issuer: authority.issuer,
      client_id: authority.client.client_id,
      principal_epoch: context.principal_epoch,
      authority_fingerprint: authority.fingerprint,
      authority_epoch: authority_epoch
    )
  end

  defp bounded_id?(value),
    do:
      byte_size(value) in 1..256 and String.valid?(value) and
        not String.contains?(value, [<<0>>, "\r", "\n"])

  defp missing_credential(_binding, _deadline), do: {:error, :credential_resolver_missing}
end
