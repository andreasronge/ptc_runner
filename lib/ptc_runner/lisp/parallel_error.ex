defmodule PtcRunner.Lisp.ParallelError do
  @moduledoc false

  defexception [:message, :reason, :eval_ctx]

  @impl true
  def exception(attrs) when is_list(attrs) do
    %__MODULE__{
      message: Keyword.get(attrs, :message, "parallel evaluation failed"),
      reason: Keyword.fetch!(attrs, :reason),
      eval_ctx: Keyword.fetch!(attrs, :eval_ctx)
    }
  end
end
