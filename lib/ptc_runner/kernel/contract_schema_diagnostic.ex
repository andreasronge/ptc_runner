defmodule PtcRunner.Kernel.ContractSchemaDiagnostic do
  @moduledoc """
  Closed projection policy for rejected value-contract schema documents.

  The supported schema profile is deliberately narrow, and its edges are not
  guessable from a bare refusal: an unsupported keyword, a misspelled type, an
  untyped node, and an unsatisfiable bound are four different authoring
  mistakes with four different fixes. Reporting them identically forces the
  author to bisect their own schema to find the boundary.

  A rejection therefore carries a closed `rule` atom, rendered here from a
  fixed literal, and the segments locating the fault. Compiler prose never
  crosses the boundary, and the pointer is minted only after every segment is
  proven to resolve in the submitted document, so a diagnostic can never name
  a location that file does not carry.
  """

  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.ValueContract

  @messages %{
    not_a_schema_object: "contract schema node is not a JSON object",
    unsupported_keyword: "contract schema uses a keyword outside the supported profile",
    type_missing: ~s(contract schema node declares no "type"),
    unsupported_type: ~s(contract schema declares an unsupported "type"),
    unsupported_format: ~s(contract schema declares an unsupported "format"),
    keyword_not_applicable: ~s(contract schema keyword does not apply to its declared "type"),
    invalid_keyword_value: "contract schema keyword has an invalid value",
    bounds_inverted: "contract schema declares a minimum above its maximum",
    required_property_undeclared: "contract schema requires a property it does not declare",
    root_not_object: "contract schema root is not an object schema",
    unsupported_dialect: ~s(contract schema declares an unsupported "$schema" dialect),
    depth_exceeded: "contract schema nests deeper than the supported profile allows",
    too_many_properties: "contract schema declares more properties than the profile allows",
    too_many_enum_members: "contract schema declares more enum members than the profile allows",
    schema_too_large: "contract schema is larger than the supported profile allows",
    union_branch_count: ~s(contract schema "oneOf" is not two to sixteen branches),
    union_branch_not_closed_object: ~s(contract schema "oneOf" branch is not a closed object),
    union_discriminator_missing:
      ~s(contract schema "oneOf" branches share no single constant discriminator)
  }

  @type detail :: %{rule: atom(), path: CommandPath.t() | nil}

  @doc """
  Locates a rejection inside the document it came from.

  The path is dropped rather than guessed when the segments do not resolve, so
  the diagnostic degrades to the catalog message instead of pointing somewhere
  the author cannot open.
  """
  @spec detail(map(), term()) :: detail()
  def detail(document, %{rule: rule, segments: segments})
      when is_atom(rule) and is_list(segments) do
    %{rule: rule, path: authorized_path(document, segments)}
  end

  def detail(_document, _rejection), do: %{rule: :unsupported_schema, path: nil}

  @doc "Renders one rule as its fixed message, or declines so the catalog literal stands."
  @spec message(term()) :: {:ok, binary()} | :error
  def message(rule) when is_atom(rule), do: Map.fetch(@messages, rule)
  def message(_rule), do: :error

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message), do: message in messages()
  def valid_message?(_message), do: false

  @doc false
  @spec messages() :: [binary()]
  def messages, do: @messages |> Map.values() |> Enum.sort()

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback),
    do: %{"enum" => Enum.sort([fallback | messages()])}

  @doc """
  Returns every rule the schema compiler can emit.

  Rules without a message fall back to the catalog literal; the set is exposed
  so a test can prove the vocabularies have not drifted apart.
  """
  @spec rules() :: [atom()]
  def rules, do: JSONSchema.rules() ++ ValueContract.union_rules()

  defp authorized_path(document, segments) do
    case CommandPath.value_contract_schema(document, segments) do
      {:ok, path} -> path
      {:error, :invalid_command_path} -> nil
    end
  end
end
