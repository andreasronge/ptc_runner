defmodule PtcGateway.Errors do
  @moduledoc """
  Closed mapping from gateway failures to JSON-RPC errors or `tools/call`
  results with `isError: true`.

  Protocol-level JSON-RPC errors never carry application result values.
  Successful JSON-RPC responses may still set `isError: true` when the tool
  ran and produced a classified failure. Private outcomes never include a
  result value in either shape.
  """

  @parse -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @admission -32_000

  @type kind ::
          :parse
          | :invalid_request
          | :method_not_found
          | :invalid_params
          | :unknown_tool
          | :admission
          | :input_contract
          | :result_contract
          | :execution
          | :cleanup
          | :private
          | :cancelled

  @spec jsonrpc?(kind()) :: boolean()
  def jsonrpc?(kind)
      when kind in [
             :parse,
             :invalid_request,
             :method_not_found,
             :invalid_params,
             :unknown_tool,
             :admission
           ],
      do: true

  def jsonrpc?(_kind), do: false

  @spec rpc_code(kind()) :: integer()
  def rpc_code(:parse), do: @parse
  def rpc_code(:invalid_request), do: @invalid_request
  def rpc_code(:method_not_found), do: @method_not_found
  def rpc_code(:invalid_params), do: @invalid_params
  def rpc_code(:unknown_tool), do: @invalid_params
  def rpc_code(:admission), do: @admission

  @spec rpc_message(kind()) :: binary()
  def rpc_message(:parse), do: "parse error"
  def rpc_message(:invalid_request), do: "invalid request"
  def rpc_message(:method_not_found), do: "method not found"
  def rpc_message(:invalid_params), do: "invalid params"
  def rpc_message(:unknown_tool), do: "unknown tool"
  def rpc_message(:admission), do: "in-flight admission rejected"

  @spec call_message(kind()) :: binary()
  def call_message(:input_contract), do: "input contract rejected"
  def call_message(:result_contract), do: "result contract rejected"
  def call_message(:execution), do: "execution failed"
  def call_message(:cleanup), do: "provider cleanup failed"
  def call_message(:private), do: "private outcome"
  def call_message(:cancelled), do: "cancelled"
end
