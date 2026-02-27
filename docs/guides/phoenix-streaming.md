# Phoenix Streaming with SubAgent.chat/3

Stream SubAgent responses token-by-token in a Phoenix LiveView chat interface.

## Overview

`SubAgent.chat/3` supports streaming via the `on_chunk` callback. In a LiveView, spawn a Task that runs `chat/3`, stream chunks to the LiveView process via `send/2`, and push them to the browser with `push_event/3`.

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
       chat_messages: [],
       streaming: false,
       current_response: ""
     )
     |> stream(:messages, [])}
  end

  @impl true
  def handle_event("send_message", %{"chat" => %{"message" => message}}, socket) do
    # Add user message to the display stream
    user_msg = %{id: System.unique_integer([:positive]), role: :user, content: message}
    lv_pid = self()
    chat_messages = socket.assigns.chat_messages

    Task.start(fn ->
      result =
        SubAgent.chat(@agent, message,
          llm: my_llm(),
          messages: chat_messages,
          on_chunk: fn %{delta: delta} -> send(lv_pid, {:chunk, delta}) end
        )

      case result do
        {:ok, _reply, updated_messages} ->
          send(lv_pid, {:chat_done, updated_messages})

        {:error, reason} ->
          send(lv_pid, {:chat_error, reason})
      end
    end)

    {:noreply,
     socket
     |> stream_insert(:messages, user_msg)
     |> assign(streaming: true, current_response: "")}
  end

  @impl true
  def handle_info({:chunk, delta}, socket) do
    current = socket.assigns.current_response <> delta

    {:noreply,
     socket
     |> assign(current_response: current)
     |> push_event("stream-chunk", %{delta: delta})}
  end

  @impl true
  def handle_info({:chat_done, updated_messages}, socket) do
    assistant_msg = %{
      id: System.unique_integer([:positive]),
      role: :assistant,
      content: socket.assigns.current_response
    }

    {:noreply,
     socket
     |> assign(streaming: false, current_response: "", chat_messages: updated_messages)
     |> stream_insert(:messages, assistant_msg)
     |> push_event("stream-done", %{})}
  end

  @impl true
  def handle_info({:chat_error, reason}, socket) do
    error_msg = %{
      id: System.unique_integer([:positive]),
      role: :assistant,
      content: "Error: #{inspect(reason)}"
    }

    {:noreply,
     socket
     |> assign(streaming: false, current_response: "")
     |> stream_insert(:messages, error_msg)}
  end

  defp my_llm do
    PtcRunner.LLM.callback("openrouter:anthropic/claude-haiku-4.5")
  end
end
```

## JavaScript Hooks

Three hooks handle the streaming UI: `StreamChat` appends chunks to the DOM, `ScrollBottom` keeps the chat scrolled down, and `ChatForm` clears the input on submit.

```javascript
// assets/js/hooks.js
export const StreamChat = {
  mounted() {
    this.handleEvent("stream-chunk", ({ delta }) => {
      const target = this.el.querySelector("[data-stream-target]")
      if (target) target.textContent += delta
    })

    this.handleEvent("stream-done", () => {
      // Streaming container will be removed on re-render
    })
  }
}

export const ScrollBottom = {
  mounted() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.scrollToBottom())
    this.observer.observe(this.el, { childList: true, subtree: true })
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  }
}

export const ChatForm = {
  mounted() {
    this.el.addEventListener("submit", () => {
      const input = this.el.querySelector("input[type=text]")
      setTimeout(() => { input.value = ""; input.focus() }, 0)
    })
  }
}
```

Register the hooks in your `app.js`:

```javascript
import { StreamChat, ScrollBottom, ChatForm } from "./hooks"

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { StreamChat, ScrollBottom, ChatForm },
  // ...
})
```

## Template

```heex
<div
  id="messages"
  phx-update="stream"
  phx-hook="ScrollBottom"
  class="flex-1 overflow-y-auto p-4"
>
  <div :for={{dom_id, msg} <- @streams.messages} id={dom_id} class={msg.role}>
    <strong><%= msg.role %>:</strong> <%= msg.content %>
  </div>
</div>

<div :if={@streaming} id="stream-container" phx-hook="StreamChat">
  <span data-stream-target></span>
</div>

<form phx-submit="send_message" phx-hook="ChatForm">
  <input type="text" name="chat[message]" placeholder="Type a message..." />
  <button type="submit" disabled={@streaming}>Send</button>
</form>
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

- `on_chunk` fires per-token in text-only mode (no tools). With tools, it fires once with the full final answer after all tool calls complete.
- The `messages` returned by `chat/3` include the system prompt. On the next call, `chat/3` automatically strips system messages before forwarding to the LLM (which regenerates the system prompt from the agent struct).
- For production use, consider adding a timeout mechanism and more granular error handling in the Task.

## See Also

- `PtcRunner.SubAgent.chat/3` - API reference
- [Getting Started](subagent-getting-started.md) - SubAgent basics
- [LLM Setup](subagent-llm-setup.md) - Provider configuration and streaming
