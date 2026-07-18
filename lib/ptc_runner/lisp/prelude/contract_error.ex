defmodule PtcRunner.Lisp.Prelude.ContractError do
  @moduledoc false

  defexception [:message, :reason, :eval_ctx]

  @impl true
  def exception(attrs) when is_list(attrs) do
    reason = Keyword.fetch!(attrs, :reason)

    %__MODULE__{
      message: Keyword.get(attrs, :message, "prelude contract failed"),
      reason: reason,
      eval_ctx: Keyword.fetch!(attrs, :eval_ctx)
    }
  end
end
