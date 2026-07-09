defmodule PtcRunner.PreludeRuntime do
  @moduledoc false

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.PreludeRolePolicy
  alias PtcRunner.PreludeRolePolicy.Grant
  alias PtcRunner.PreludeStore
  alias PtcRunner.PreludeStore.Selection

  @type resolved :: %{
          prelude: Prelude.t(),
          selected_refs: [term()],
          resolved_refs: [map()],
          role: String.t(),
          grant_fingerprint: String.t(),
          prelude_store_access: :none | :read | :write
        }

  @spec resolve(PreludeStore.t() | nil, Grant.t(), keyword()) ::
          {:ok, resolved()} | {:error, map()}
  def resolve(store, %Grant{} = grant, opts) when is_list(opts) do
    with {:ok, selected_refs} <- PreludeRolePolicy.selected_refs(grant, opts),
         :ok <- require_store(store, selected_refs) do
      try do
        {prelude, resolved_refs} = Selection.resolve!(store, selected_refs, opts)

        case prelude do
          %Prelude{} = prelude ->
            {:ok,
             %{
               prelude: prelude,
               selected_refs: selected_refs,
               resolved_refs: resolved_refs,
               role: grant.role,
               grant_fingerprint: grant.fingerprint,
               prelude_store_access: grant.prelude_store_access
             }}

          nil ->
            {:error,
             error(:missing_prelude_selection, "role #{inspect(grant.role)} selected no preludes")}
        end
      rescue
        e in ArgumentError ->
          {:error, error(:prelude_selection_failed, Exception.message(e))}
      end
    end
  end

  defp require_store(%PreludeStore{}, _refs), do: :ok

  defp require_store(nil, refs) when refs != [] do
    {:error, error(:missing_prelude_store, ":prelude_store is required for role-backed preludes")}
  end

  defp require_store(nil, _refs),
    do:
      {:error,
       error(:missing_prelude_store, ":prelude_store is required for role-backed preludes")}

  defp require_store(store, _refs) do
    {:error,
     error(
       :invalid_prelude_store,
       ":prelude_store must be a %PtcRunner.PreludeStore{}, got: #{inspect(store)}"
     )}
  end

  defp error(reason, message), do: %{reason: reason, message: message}
end
