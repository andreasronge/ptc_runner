# Phoenix Streaming with SubAgent.chat/3

This guide shows how to stream SubAgent responses token-by-token in a Phoenix LiveView chat interface.

## Overview

`SubAgent.chat/3` supports streaming via the `on_chunk` callback. In a LiveView, you spawn a Task that runs `chat/3`, stream chunks to the LiveView process via `send/2`, and push them to the browser with `push_event/3`.

## LiveView Module

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  alias PtcRunner.SubAgent

  @agent SubAgent.new(
    prompt: "placeholder",
    output: :text,
    system_prompt: "You are a helpful assistant."
  )

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       messages: [],
       streaming: false,
       current_response: ""
     )}
  end

  @impl true
  def handle_event("send_message", %{"message" => user_msg}, socket) do
    # Add user message to display
    messages = socket.assigns.messages ++ [%{role: :user, content: user_msg}]
    lv_pid = self()

    # Spawn a task to run chat without blocking the LiveView
    Task.start(fn ->
      {:ok, _reply, updated_messages} =
        SubAgent.chat(@agent, user_msg,
          llm: my_llm(),
          messages: socket.assigns.messages,
          on_chunk: fn %{delta: delta} ->
            send(lv_pid, {:chunk, delta})
          end
        )

      send(lv_pid, {:chat_done, updated_messages})
    end)

    {:noreply, assign(socket, messages: messages, streaming: true, current_response: "")}
  end

  @impl true
  def handle_info({:chunk, delta}, socket) do
    current = socket.assigns.current_response <> delta
    {:noreply, push_event(socket, "stream-chunk", %{delta: delta}) |> assign(current_response: current)}
  end

  @impl true
  def handle_info({:chat_done, updated_messages}, socket) do
    {:noreply,
     assign(socket,
       messages: updated_messages,
       streaming: false,
       current_response: ""
     )}
  end

  defp my_llm do
    PtcRunner.LLM.callback("openrouter:anthropic/claude-haiku-4.5")
  end
end
```

## JavaScript Hook

Add a JS hook to append streamed text to the DOM:

```javascript
// assets/js/hooks/stream_hook.js
const StreamHook = {
  mounted() {
    this.handleEvent("stream-chunk", ({ delta }) => {
      const target = document.getElementById("assistant-response")
      if (target) {
        target.textContent += delta
      }
    })
  }
}

export default StreamHook
```

Register the hook in your `app.js`:

```javascript
import StreamHook from "./hooks/stream_hook"

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { StreamHook },
  // ...
})
```

## Template

```heex
<div id="chat" phx-hook="StreamHook">
  <%!-- Filter out tool messages and nil content from tool-calling turns --%>
  <div :for={msg <- @messages, msg.role in [:user, :assistant] and msg[:content]} class={msg.role}>
    <strong><%= msg.role %>:</strong> <%= msg.content %>
  </div>

  <div :if={@streaming} id="assistant-response" class="assistant">
    <!-- Chunks append here via JS hook -->
  </div>

  <form phx-submit="send_message">
    <input type="text" name="message" placeholder="Type a message..." />
    <button type="submit" disabled={@streaming}>Send</button>
  </form>
</div>
```

## Alternative: No JavaScript (Assign-Based)

If you prefer to avoid JS hooks, update an assign on each chunk and let LiveView re-render:

```elixir
def handle_info({:chunk, delta}, socket) do
  current = socket.assigns.current_response <> delta
  {:noreply, assign(socket, current_response: current)}
end
```

```heex
<p :if={@streaming}><%= @current_response %></p>
```

**Warning:** This re-renders the LiveView on every single token. When the LLM streams fast, this can lock up the browser. For production use, buffer chunks and flush on a timer:

```elixir
def handle_info({:chunk, delta}, socket) do
  buffer = (socket.assigns[:chunk_buffer] || "") <> delta

  # Schedule a flush if not already pending
  unless socket.assigns[:flush_pending] do
    Process.send_after(self(), :flush_chunks, 50)
  end

  {:noreply, assign(socket, chunk_buffer: buffer, flush_pending: true)}
end

def handle_info(:flush_chunks, socket) do
  current = socket.assigns.current_response <> (socket.assigns[:chunk_buffer] || "")
  {:noreply, assign(socket, current_response: current, chunk_buffer: "", flush_pending: false)}
end
```

The JS hook approach above is generally more efficient and recommended.

## Notes

- `on_chunk` fires per-token in text-only mode (no tools). With tools, it fires once with the full final answer after all tool calls complete. Real-time streaming of the final answer in tool mode is planned for v2.
- The `messages` returned by `chat/3` include the system prompt. On the next call, `chat/3` automatically strips system messages before forwarding to the LLM (which regenerates the system prompt from the agent struct).
- For production use, consider adding error handling in the Task and a timeout mechanism.

## See Also

- `PtcRunner.SubAgent.chat/3` - API reference
- [Getting Started](subagent-getting-started.md) - SubAgent basics
- [LLM Setup](subagent-llm-setup.md) - Provider configuration and streaming
