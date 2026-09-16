defmodule PtcRunner.Kernel.Attestation do
  @moduledoc """
  Internal in-VM construction attestation for sealed Kernel values.

  This detects accidental or caller-authored struct mutation across trusted
  construction boundaries. It is not a security boundary against trusted code
  running in the same VM. One-shot execution processes may enable a local
  validation cache. A cache hit still compares the complete immutable value;
  it only avoids repeating nested validation and deterministic serialization.
  """

  @validation_cache_key {__MODULE__, :validation_cache}

  @spec attest(module(), term()) :: binary()
  def attest(owner, payload) when is_atom(owner) do
    :crypto.mac(:hmac, :sha256, key(owner), :erlang.term_to_binary(payload, [:deterministic]))
  end

  @spec valid?(module(), term(), term()) :: boolean()
  def valid?(owner, payload, attestation) when is_atom(owner) and is_binary(attestation) do
    case validation_cache() do
      nil -> secure_compare(attestation, attest(owner, payload))
      cache -> cached_valid?(cache, owner, payload, attestation)
    end
  end

  def valid?(_owner, _payload, _attestation), do: false

  @doc false
  @spec valid_struct?(module(), struct(), [atom()], (-> term())) :: boolean()
  def valid_struct?(owner, value, expected_keys, payload)
      when is_atom(owner) and is_struct(value) and is_list(expected_keys) and
             is_function(payload, 0) do
    valid_value?(owner, value, Map.get(value, :attestation), fn ->
      Enum.sort(Map.keys(value)) == expected_keys and
        valid?(owner, payload.(), Map.get(value, :attestation))
    end)
  end

  def valid_struct?(_owner, _value, _expected_keys, _payload), do: false

  @doc false
  @spec valid_value?(module(), term(), term(), (-> boolean())) :: boolean()
  def valid_value?(owner, value, attestation, validate)
      when is_atom(owner) and is_binary(attestation) and is_function(validate, 0) do
    case validation_cache() do
      nil -> validate.()
      cache -> cached_value_valid?(cache, owner, value, attestation, validate)
    end
  end

  def valid_value?(_owner, _value, _attestation, _validate), do: false

  @doc false
  @spec with_validation_cache((-> result)) :: result when result: term()
  def with_validation_cache(fun) when is_function(fun, 0) do
    if validation_cache_enabled?() do
      fun.()
    else
      cache = enable_new_validation_cache()

      try do
        fun.()
      after
        Process.delete(@validation_cache_key)
        :ets.delete(cache)
      end
    end
  end

  @doc false
  @spec enable_validation_cache() :: :ok
  def enable_validation_cache do
    unless validation_cache_enabled?(), do: enable_new_validation_cache()
    :ok
  end

  @doc false
  @spec validation_cache_enabled?() :: boolean()
  def validation_cache_enabled?, do: not is_nil(validation_cache())

  @spec cached_valid?(:ets.table(), module(), term(), binary()) :: boolean()
  defp cached_valid?(cache, owner, payload, attestation) do
    cache_key = {owner, attestation}

    case :ets.lookup(cache, cache_key) do
      [{^cache_key, validated_payload}] ->
        validated_payload === payload

      [] ->
        if secure_compare(attestation, attest(owner, payload)) do
          true = :ets.insert(cache, {cache_key, payload})
          true
        else
          false
        end
    end
  end

  @spec cached_value_valid?(:ets.table(), module(), term(), binary(), (-> boolean())) :: boolean()
  defp cached_value_valid?(cache, owner, value, attestation, validate) do
    cache_key = {:value, owner, attestation}

    case :ets.lookup(cache, cache_key) do
      [{^cache_key, validated_value}] ->
        validated_value === value

      [] ->
        if validate.() do
          true = :ets.insert(cache, {cache_key, value})
          true
        else
          false
        end
    end
  end

  defp enable_new_validation_cache do
    cache = :ets.new(__MODULE__, [:set, :private])
    Process.put(@validation_cache_key, cache)
    cache
  end

  @spec validation_cache() :: :ets.table() | nil
  defp validation_cache, do: Process.get(@validation_cache_key)

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_compare(_left, _right), do: false

  defp key(owner) do
    storage_key = {__MODULE__, owner}

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
