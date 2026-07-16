defmodule PtcRunner.Kernel.MissionInventory do
  @moduledoc """
  Builds the exact frozen model-facing inventory for one mission environment.

  Version 1 contains prompt-visible prelude exports, model-visible capability
  schemas, and the mission execution limits relevant to generated programs.
  Arrays are sorted by public reference/name. The compact UTF-8 rendering and
  lower-case SHA-256 hash are frozen into `PtcRunner.Kernel.RunConfig` and are
  identical for normal runs and `PtcRunner.Kernel.ReplSession`.

  Rendering uses `PtcRunner.Kernel.DeterministicJSON`. The installed ceiling
  is 256 KiB; callers may lower it but inventory is never truncated.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Environment
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Export

  @max_bytes 256 * 1_024
  @enforce_keys [:schema_version, :rendered, :hash, :bytes]
  defstruct [:schema_version, :rendered, :hash, :bytes]

  @type t :: %__MODULE__{
          schema_version: 1,
          rendered: binary(),
          hash: binary(),
          bytes: non_neg_integer()
        }

  @spec build(MissionEnvironment.t(), Limits.t(), keyword()) ::
          {:ok, t()} | {:error, :invalid_mission_inventory | :mission_inventory_exceeded}
  @doc "Builds one bounded version 1 mission inventory."
  def build(mission, limits, opts \\ [])

  def build(%MissionEnvironment{} = mission, %Limits{} = limits, opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- [:max_bytes] == [],
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <-
           Keyword.get(opts, :max_bytes, @max_bytes),
         {:ok, rendered} <- DeterministicJSON.encode(projection(mission, limits)),
         true <- byte_size(rendered) <= max_bytes do
      {:ok,
       %__MODULE__{
         schema_version: 1,
         rendered: rendered,
         hash: sha256(rendered),
         bytes: byte_size(rendered)
       }}
    else
      false -> {:error, :mission_inventory_exceeded}
      _reason -> {:error, :invalid_mission_inventory}
    end
  end

  def build(_mission, _limits, _opts), do: {:error, :invalid_mission_inventory}

  defp projection(mission, limits) do
    {:object,
     [
       {"schema_version", 1},
       {"exports", exports(mission)},
       {"capabilities", capabilities(mission)},
       {"limits", limit_projection(limits)}
     ]}
  end

  defp exports(%{bundle: %{prelude: prelude}}) do
    prelude
    |> Prelude.prompt_exports()
    |> Enum.sort_by(& &1.ref)
    |> Enum.map(&export_projection/1)
  end

  defp exports(_mission), do: []

  defp export_projection(%Export{} = export) do
    {:object,
     [
       {"ref", export.ref},
       {"kind", Atom.to_string(export.kind)},
       {"call", export_call(export)},
       {"doc", export.doc},
       {"effect", Atom.to_string(export.effect)},
       {"contract", export.signature || export.type}
     ]}
  end

  defp export_call(%Export{kind: :constant, ref: ref}), do: ref

  defp export_call(%Export{} = export) do
    export
    |> Export.signature()
    |> String.replace_prefix("(#{export.symbol}", "(#{export.ref}")
  end

  defp capabilities(mission) do
    mission
    |> Environment.metadata()
    |> Enum.map(fn capability ->
      {:object,
       [
         {"name", capability.name},
         {"description", capability.description},
         {"effect", Atom.to_string(capability.effect)},
         {"input_schema", capability.input_schema},
         {"output_schema", capability.output_schema}
       ]}
    end)
  end

  defp limit_projection(limits) do
    {:object,
     [
       {"evaluation_timeout_ms", limits.evaluation_timeout_ms},
       {"subordinate_source_bytes", limits.subordinate_source_bytes},
       {"mission_capability_calls", limits.mission_capability_calls},
       {"mission_capability_calls_per_name", limits.mission_capability_calls_per_name},
       {"capability_argument_bytes", limits.capability_argument_bytes},
       {"capability_result_bytes", limits.capability_result_bytes}
     ]}
  end

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
