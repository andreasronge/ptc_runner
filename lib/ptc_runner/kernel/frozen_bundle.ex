defmodule PtcRunner.Kernel.FrozenBundle do
  @moduledoc """
  An immutable, deterministically ordered component compilation result.

  Bundles contain compiled component metadata, ordered component IDs, an
  aggregate graph hash, and the compiled PTC-Lisp prelude. The graph hash is
  bare lowercase SHA-256 over the canonical `ptc.frozen-bundle.v2` framing of
  every component ID, source hash, and sorted unique direct dependency list.
  It therefore changes when code or dependency edges change and does not
  depend on Erlang external-term encoding.

  All integer fields in the framing are unsigned big-endian:

  ```text
  "ptc.frozen-bundle.v2\\0" ||
  u32(component_count) ||
  for each component sorted by UTF-8 component-ID bytes:
    0x01 ||
    u32(component_id_bytes) || component_id ||
    u64(payload_bytes) || payload
  ```

  The sole record kind is `0x01`. Its payload is RFC 8785 canonical JSON of
  exactly `{"dependencies":[...],"source_hash":"..."}`. Dependencies are
  sorted unique direct component IDs and `source_hash` is the existing bare
  lowercase SHA-256 hex digest. Component IDs and dependencies are UTF-8
  strings; neither field is nullable or omitted.

  An in-VM attestation prevents callers from mutating a bundle struct and
  presenting it as compiler output during environment assembly.

  Hosts obtain bundles through `PtcRunner.Kernel.compile_bundle/1`; `seal/1`
  and `valid?/1` support the Kernel's construction boundary.
  """
  import Bitwise, only: [bor: 2, bxor: 2]
  @enforce_keys [:components, :component_ids, :hash, :prelude]
  defstruct [:components, :component_ids, :hash, :prelude, :attestation]
  @field_keys Enum.sort([:__struct__, :components, :component_ids, :hash, :prelude, :attestation])

  @type t :: %__MODULE__{
          components: [map()],
          component_ids: [binary()],
          hash: binary(),
          prelude: PtcRunner.Lisp.Prelude.t(),
          attestation: binary() | nil
        }

  @spec trace_metadata(t() | nil) ::
          {:ok,
           %{
             component_ids: [binary()],
             dependency_indices: [[non_neg_integer()]],
             hash: binary() | nil
           }}
          | {:error, :invalid_bundle}
  @doc """
  Derives the compact canonical dependency projection for `run-started`.

  `dependency_indices` is positionally aligned with `component_ids`: the
  list at position `i` holds the unique, ascending indices of that
  component's direct dependencies, and every index is strictly less than
  `i` (the frozen order places dependencies before dependants, so forward
  references and cycles are unrepresentable). A missing bundle projects to
  empty lists and a nil hash. Component source, origins, namespaces, and
  other compilation data never enter the projection.
  """
  def trace_metadata(nil), do: {:ok, %{component_ids: [], dependency_indices: [], hash: nil}}

  def trace_metadata(%__MODULE__{} = bundle) do
    positions = bundle.component_ids |> Enum.with_index() |> Map.new()

    bundle.components
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {component, position}, {:ok, acc} ->
      indices =
        component.dependencies
        |> Enum.map(&Map.get(positions, &1))
        |> Enum.sort()

      valid? =
        indices == Enum.uniq(indices) and
          Enum.all?(indices, &(is_integer(&1) and &1 >= 0 and &1 < position))

      if valid?, do: {:cont, {:ok, [indices | acc]}}, else: {:halt, {:error, :invalid_bundle}}
    end)
    |> case do
      {:ok, indices} ->
        {:ok,
         %{
           component_ids: bundle.component_ids,
           dependency_indices: Enum.reverse(indices),
           hash: bundle.hash
         }}

      {:error, _reason} = error ->
        error
    end
  end

  @spec seal(t()) :: t()
  @doc "Attests a newly compiled bundle for later environment validation."
  def seal(%__MODULE__{} = bundle), do: %{bundle | attestation: attest(bundle)}

  @spec valid?(t()) :: boolean()
  @doc "Checks that a bundle still matches its in-VM attestation."
  def valid?(%__MODULE__{attestation: attestation} = bundle) when is_binary(attestation),
    do:
      Enum.sort(Map.keys(bundle)) == @field_keys and
        secure_compare(attestation, attest(bundle))

  def valid?(_bundle), do: false

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {left_byte, right_byte}, difference ->
      bor(difference, bxor(left_byte, right_byte))
    end)
    |> Kernel.==(0)
  end

  defp secure_compare(_left, _right), do: false

  defp attest(bundle) do
    :crypto.mac(:hmac, :sha256, key(), canonical(bundle))
  end

  defp canonical(bundle) do
    :erlang.term_to_binary(
      {bundle.components, bundle.component_ids, bundle.hash, bundle.prelude},
      [:deterministic]
    )
  end

  defp key do
    storage_key = {__MODULE__, :attestation_key}

    case :persistent_term.get(storage_key, :missing) do
      :missing ->
        :global.trans({storage_key, self()}, fn ->
          case :persistent_term.get(storage_key, :missing) do
            :missing ->
              secret = :crypto.strong_rand_bytes(32)
              :persistent_term.put(storage_key, secret)
              secret

            secret ->
              secret
          end
        end)

      secret ->
        secret
    end
  end
end
