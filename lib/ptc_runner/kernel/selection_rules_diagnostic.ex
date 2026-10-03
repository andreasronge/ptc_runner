defmodule PtcRunner.Kernel.SelectionRulesDiagnostic do
  @moduledoc """
  Closed messages for provider-selection rule failures.

  Messages name only sealed selection-rule fields, sealed named sets, and a
  closed rule vocabulary. Rejected values, caller-authored keys, and
  installation aliases never cross this boundary.
  """

  alias PtcRunner.Kernel.DiagnosticPattern

  @field "[a-z][a-z0-9._-]{0,127}"
  @unknown_property "the provider selection contains an unknown property"
  @max_message_bytes 323
  @templates [
    {:field,
     [
       {:literal, "the provider selection field "},
       {:slot, :field, :text, @field},
       {:literal, " is invalid"}
     ]},
    {:members,
     [
       {:literal, "the provider selection field "},
       {:slot, :field, :text, @field},
       {:literal, " contains a name outside its allowed set"}
     ]},
    {:subset_of,
     [
       {:literal, "the provider selection field "},
       {:slot, :child, :text, @field},
       {:literal, " must be a subset of "},
       {:slot, :parent, :text, @field}
     ]},
    {:required_when_write,
     [
       {:literal, "the provider selection field "},
       {:slot, :field, :text, @field},
       {:literal, " is required because the installation maps a write"}
     ]},
    {:required_when_set_nonempty,
     [
       {:literal, "the provider selection field "},
       {:slot, :field, :text, @field},
       {:literal, " is required when the "},
       {:slot, :set, :text, @field},
       {:literal, " set is nonempty"}
     ]},
    {:required,
     [
       {:literal, "the provider selection field "},
       {:slot, :field, :text, @field},
       {:literal, " is required"}
     ]},
    {:ceiling,
     [
       {:literal, "the provider selection field "},
       {:slot, :field, :text, @field},
       {:literal, " exceeds an installed or context ceiling"}
     ]}
  ]

  @type rejection ::
          :unknown_property
          | {:field, binary()}
          | {:members, binary()}
          | {:required, binary()}
          | {:subset_of, binary(), binary()}
          | {:required_when_set_nonempty, binary(), binary()}
          | {:ceiling, binary()}

  @doc "Renders one closed selection-rule rejection."
  @spec message(term()) :: {:ok, binary()} | :error
  def message(:unknown_property), do: {:ok, @unknown_property}

  def message({:required_when_set_nonempty, field, "write"}),
    do: build(:required_when_write, %{field: field})

  def message({:required_when_set_nonempty, field, set}),
    do: build(:required_when_set_nonempty, %{field: field, set: set})

  def message({:subset_of, child, parent}), do: build(:subset_of, %{child: child, parent: parent})

  def message({kind, field}) when kind in [:field, :members, :required, :ceiling],
    do: build(kind, %{field: field})

  def message(_rejection), do: :error

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) do
    message == @unknown_property or
      Enum.any?(@templates, fn {kind, template} ->
        DiagnosticPattern.valid_template?(template, message, &build(kind, &1))
      end)
  end

  @doc false
  @spec message_schema(binary()) :: map()
  def message_schema(fallback) when is_binary(fallback) do
    %{
      "oneOf" => [
        %{"const" => fallback},
        %{"const" => @unknown_property}
        | Enum.map(@templates, fn {_kind, template} ->
            DiagnosticPattern.exact_message_schema(@max_message_bytes, template)
          end)
      ]
    }
  end

  defp build(kind, values) do
    template = Keyword.fetch!(@templates, kind)

    if not (kind == :required_when_set_nonempty and values.set == "write") and
         Enum.all?(values, fn {_name, value} ->
           is_binary(value) and
             Regex.match?(Regex.compile!(DiagnosticPattern.exact(@field)), value)
         end) do
      {:ok, DiagnosticPattern.render(template, values)}
    else
      :error
    end
  end
end
