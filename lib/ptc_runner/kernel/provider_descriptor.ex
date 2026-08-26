defmodule PtcRunner.Kernel.ProviderDescriptor do
  @moduledoc """
  Sealed, declarative metadata for one installed provider implementation.

  Descriptors contain no executable callback, credential value, endpoint,
  command, path, OAuth authority, store/context, grant, token manager, or principal. Phase
  5 may therefore normalize selections and compute identity without consulting
  an implementation or crossing the provider-activity boundary.

  `local_preflight` is a trust declaration rather than a capability flag. Only a
  shipped source may declare `:audited_local`, because that value permits phase
  7 to run the callback behind it before provider activity is marked. A
  `:custom` registration declares `:unverified` instead, and its check becomes
  active work after the phase-8 marker.
  Live LLM installations also seal `structured_output_mode` here so acquisition
  can reconstruct the same workflow route the prepare callback reports.
  Public snapshots and `models` rows omit that field.
  `PtcRunner.Kernel.InstallationCatalog` completes the rule: an
  `:audited_local` declaration also requires a host runtime binding. Both rules
  bound what may be declared; neither attests where an admitted implementation
  came from.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.SelectionRules

  @sources [
    :mcp,
    :llm,
    :llm_replay,
    :ptc_trace_snapshot,
    :ptc_private_trace_snapshot,
    :ptc_inspection_snapshot,
    :custom
  ]
  @data_classes [:normal, :private_inspection]
  @destinations [:workflow, :mission]
  @revision ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @name @revision

  @enforce_keys [
    :source,
    :installation_revision,
    :credential_names,
    :authorization_mode,
    :data_class,
    :accepts_data,
    :requires,
    :provides,
    :destinations,
    :workflow_llm?,
    :connectivity_mode,
    :probe_effect,
    :selection_validation,
    :selection_rules,
    :authority_fingerprint,
    :local_preflight,
    :structured_output_mode
  ]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])
  @structured_output_modes [:json_schema, :json_object, :unsupported]

  @type source ::
          :mcp
          | :llm
          | :llm_replay
          | :ptc_trace_snapshot
          | :ptc_private_trace_snapshot
          | :ptc_inspection_snapshot
          | :custom
  @type data_policy :: %{
          data_class: :normal | :private_inspection,
          accepts_data: [:normal | :private_inspection]
        }
  @type t :: %__MODULE__{
          source: source(),
          installation_revision: binary(),
          credential_names: [binary()],
          authorization_mode: :none | :oauth,
          data_class: :normal | :private_inspection,
          accepts_data: [:normal | :private_inspection],
          requires: [atom()],
          provides: [atom()],
          destinations: [:workflow | :mission],
          workflow_llm?: boolean(),
          connectivity_mode: :none | :acquisition | :probe,
          probe_effect: nil | :metadata | :completion,
          selection_validation: :declarative | :active,
          selection_rules: SelectionRules.t(),
          authority_fingerprint: binary() | nil,
          local_preflight: :none | :audited_local | :unverified,
          structured_output_mode: :json_schema | :json_object | :unsupported | nil,
          attestation: binary() | nil
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_provider_descriptor}
  @doc "Validates and seals one provider declaration."
  def new(opts) when is_list(opts) do
    opts =
      if Keyword.keyword?(opts) do
        Keyword.put_new(
          opts,
          :structured_output_mode,
          default_structured_output_mode(Keyword.get(opts, :source))
        )
      else
        opts
      end

    if Keyword.keyword?(opts) and
         Enum.sort(Keyword.keys(opts)) == Enum.sort(@enforce_keys) and
         length(opts) == length(@enforce_keys) do
      descriptor =
        __MODULE__
        |> struct!(opts)
        |> Map.update!(:accepts_data, &sort_classes/1)
        |> Map.update!(:destinations, &sort_destinations/1)

      if valid_shape?(descriptor) do
        {:ok,
         %{
           descriptor
           | attestation: Attestation.attest(__MODULE__, payload(descriptor))
         }}
      else
        {:error, :invalid_provider_descriptor}
      end
    else
      {:error, :invalid_provider_descriptor}
    end
  rescue
    _exception -> {:error, :invalid_provider_descriptor}
  end

  def new(_opts), do: {:error, :invalid_provider_descriptor}

  @spec valid?(term()) :: boolean()
  @doc "Checks the closed descriptor shape and construction seal."
  def valid?(%__MODULE__{attestation: attestation} = descriptor),
    do:
      Enum.sort(Map.keys(descriptor)) == @field_keys and
        valid_shape?(descriptor) and
        descriptor.accepts_data == sort_classes(descriptor.accepts_data) and
        descriptor.destinations == sort_destinations(descriptor.destinations) and
        Attestation.valid?(__MODULE__, payload(descriptor), attestation)

  def valid?(_descriptor), do: false

  @spec data_policy(t()) :: data_policy()
  @doc """
  Projects the declared data policy a run-bound builder must honor.

  Run-bound registries carry only this projection. A complete descriptor also
  holds selection rules, which are bounded but large enough that copying them
  into every provider worker would compete with the provider heap limit.
  """
  def data_policy(%__MODULE__{} = descriptor),
    do: %{data_class: descriptor.data_class, accepts_data: descriptor.accepts_data}

  @spec public_projection(t(), binary(), map()) :: map()
  @doc "Projects only selector-safe declaration identity for one occurrence."
  def public_projection(%__MODULE__{} = descriptor, name, normalized_config)
      when is_binary(name) and is_map(normalized_config) do
    %{
      "name" => name,
      "source" => Atom.to_string(descriptor.source),
      "installation_revision" => descriptor.installation_revision,
      "data_class" => Atom.to_string(descriptor.data_class),
      "accepts_data" => Enum.map(descriptor.accepts_data, &Atom.to_string/1),
      "authorization_mode" => Atom.to_string(descriptor.authorization_mode),
      "config" => normalized_config
    }
  end

  @spec display_projection(t(), binary()) :: map()
  @doc "Returns safe installed metadata suitable for `models` and contexts."
  def display_projection(%__MODULE__{} = descriptor, name) when is_binary(name) do
    %{
      "alias" => name,
      "source" => Atom.to_string(descriptor.source),
      "installation_revision" => descriptor.installation_revision,
      "data_class" => Atom.to_string(descriptor.data_class),
      "accepts_data" => Enum.map(descriptor.accepts_data, &Atom.to_string/1),
      "destinations" => Enum.map(descriptor.destinations, &Atom.to_string/1)
    }
  end

  defp valid_shape?(descriptor) do
    valid_identity?(descriptor) and valid_data_policy?(descriptor) and
      valid_runtime_contract?(descriptor) and
      valid_authority_fingerprint?(
        descriptor.authorization_mode,
        descriptor.authority_fingerprint
      ) and
      shipped_consistent?(descriptor)
  end

  defp valid_identity?(descriptor),
    do:
      descriptor.source in @sources and is_binary(descriptor.installation_revision) and
        descriptor.installation_revision =~ @revision and
        valid_names?(descriptor.credential_names, 128) and
        descriptor.authorization_mode in [:none, :oauth]

  defp valid_data_policy?(descriptor),
    do:
      descriptor.data_class in @data_classes and valid_classes?(descriptor.accepts_data) and
        valid_services?(descriptor.requires) and valid_services?(descriptor.provides) and
        MapSet.disjoint?(MapSet.new(descriptor.requires), MapSet.new(descriptor.provides)) and
        valid_destinations?(descriptor.destinations)

  defp valid_runtime_contract?(descriptor),
    do:
      is_boolean(descriptor.workflow_llm?) and
        descriptor.connectivity_mode in [:none, :acquisition, :probe] and
        valid_probe_effect?(descriptor.connectivity_mode, descriptor.probe_effect) and
        descriptor.selection_validation in [:declarative, :active] and
        SelectionRules.valid?(descriptor.selection_rules) and
        descriptor.local_preflight in [:none, :audited_local, :unverified] and
        valid_structured_output_mode?(descriptor.source, descriptor.structured_output_mode)

  defp valid_structured_output_mode?(:llm, mode) when mode in @structured_output_modes,
    do: true

  defp valid_structured_output_mode?(source, nil) when source != :llm, do: true
  defp valid_structured_output_mode?(_source, _mode), do: false

  defp default_structured_output_mode(:llm), do: :unsupported
  defp default_structured_output_mode(_source), do: nil

  defp valid_names?(names, maximum) when is_list(names) and length(names) <= maximum,
    do:
      names == Enum.sort(Enum.uniq(names)) and
        Enum.all?(names, &(is_binary(&1) and &1 =~ @name))

  defp valid_names?(_names, _maximum), do: false

  defp valid_classes?(classes) when is_list(classes) and classes != [],
    do:
      classes == sort_classes(classes) and
        Enum.all?(classes, &(&1 in @data_classes))

  defp valid_classes?(_classes), do: false

  defp valid_services?(services) when is_list(services) and length(services) <= 32,
    do:
      services == Enum.sort(Enum.uniq(services)) and
        Enum.all?(services, &is_atom/1)

  defp valid_services?(_services), do: false

  defp valid_destinations?(destinations) when is_list(destinations) and destinations != [],
    do:
      destinations == sort_destinations(destinations) and
        Enum.all?(destinations, &(&1 in @destinations))

  defp valid_destinations?(_destinations), do: false

  defp valid_probe_effect?(:probe, effect), do: effect in [:metadata, :completion]
  defp valid_probe_effect?(mode, nil) when mode in [:none, :acquisition], do: true
  defp valid_probe_effect?(_mode, _effect), do: false

  defp valid_authority_fingerprint?(:none, nil), do: true

  defp valid_authority_fingerprint?(:oauth, "v1:" <> digest),
    do: byte_size(digest) == 64 and digest =~ ~r/\A[0-9a-f]{64}\z/

  defp valid_authority_fingerprint?(_mode, _fingerprint), do: false

  # `:audited_local` is a claim that the callback behind it is shipped,
  # code-owned code that phase 7 may run before provider activity is marked. A
  # custom registration cannot make that claim about itself, so it declares
  # `:unverified` and its check runs after the phase-8 marker instead. The
  # remaining clauses constrain the shipped sources that may.
  defp shipped_consistent?(%{source: :custom} = descriptor),
    do: descriptor.local_preflight != :audited_local

  defp shipped_consistent?(%{source: :mcp} = descriptor),
    do:
      descriptor.destinations == [:mission] and not descriptor.workflow_llm? and
        descriptor.connectivity_mode == :acquisition

  defp shipped_consistent?(%{source: :llm} = descriptor),
    do:
      descriptor.destinations == [:workflow] and descriptor.workflow_llm? and
        descriptor.authorization_mode == :none and descriptor.connectivity_mode == :probe

  defp shipped_consistent?(%{source: :llm_replay} = descriptor),
    do:
      descriptor.destinations == [:workflow] and descriptor.workflow_llm? and
        descriptor.authorization_mode == :none and descriptor.connectivity_mode == :none

  defp shipped_consistent?(%{source: :ptc_trace_snapshot} = descriptor),
    do:
      descriptor.destinations == [:mission] and not descriptor.workflow_llm? and
        descriptor.authorization_mode == :none and descriptor.connectivity_mode == :none and
        descriptor.provides == [:canonical_trace_snapshot] and descriptor.data_class == :normal and
        descriptor.accepts_data == [:normal, :private_inspection]

  defp shipped_consistent?(%{source: :ptc_private_trace_snapshot} = descriptor),
    do:
      descriptor.destinations == [:mission] and not descriptor.workflow_llm? and
        descriptor.authorization_mode == :none and descriptor.connectivity_mode == :none and
        descriptor.provides == [:canonical_trace_snapshot] and
        descriptor.data_class == :private_inspection and
        descriptor.accepts_data == [:normal, :private_inspection]

  defp shipped_consistent?(%{source: :ptc_inspection_snapshot} = descriptor),
    do:
      descriptor.destinations == [:mission] and not descriptor.workflow_llm? and
        descriptor.authorization_mode == :none and descriptor.connectivity_mode == :none and
        descriptor.requires == [:canonical_trace_snapshot] and
        descriptor.data_class == :private_inspection and
        descriptor.accepts_data == [:normal, :private_inspection]

  defp sort_classes(classes),
    do: Enum.sort_by(classes, &Enum.find_index(@data_classes, fn class -> class == &1 end))

  defp sort_destinations(destinations),
    do:
      Enum.sort_by(
        destinations,
        &Enum.find_index(@destinations, fn destination -> destination == &1 end)
      )

  defp payload(descriptor) do
    descriptor
    |> Map.from_struct()
    |> Map.delete(:attestation)
  end
end
