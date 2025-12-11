defmodule PtcDemo.TestHelpers do
  def without_api_keys(fun) do
    old_key = System.get_env("OPENROUTER_API_KEY")

    try do
      System.delete_env("OPENROUTER_API_KEY")
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_API_KEY")
      fun.()
    after
      if old_key, do: System.put_env("OPENROUTER_API_KEY", old_key)
    end
  end
end
