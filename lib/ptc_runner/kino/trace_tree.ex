if Code.ensure_loaded?(Kino.JS) do
  defmodule PtcRunner.Kino.TraceTree do
    @moduledoc """
    Interactive trace tree widget for Livebook.

    Renders a hierarchical view of SubAgent execution from a `Step` struct,
    showing agent names, durations, token counts, and expandable turn details.

    ## Usage

        {result, step} = SubAgent.run(planner, llm: my_llm, context: ctx, debug: true)
        PtcRunner.Kino.TraceTree.new(step)

    The widget works with the in-memory Step struct. For multi-agent hierarchies,
    pass a list of related steps:

        PtcRunner.Kino.TraceTree.new([parent_step, child1_step, child2_step])

    Requires the `kino` dependency.
    """

    use Kino.JS

    @doc """
    Creates a new TraceTree widget from a Step or list of Steps.

    ## Examples

        PtcRunner.Kino.TraceTree.new(step)
        PtcRunner.Kino.TraceTree.new([parent_step, child_step1, child_step2])

    """
    @spec new(PtcRunner.Step.t() | [PtcRunner.Step.t()]) :: Kino.JS.t()
    def new(%PtcRunner.Step{} = step) do
      tree_data = %{nodes: [build_node(step)]}
      Kino.JS.new(__MODULE__, tree_data)
    end

    def new(steps) when is_list(steps) do
      tree_data = build_tree(steps)
      Kino.JS.new(__MODULE__, tree_data)
    end

    asset "main.js" do
      """
      export function init(ctx, treeData) {
        ctx.root.innerHTML = renderRoot(treeData);

        ctx.root.addEventListener("click", (e) => {
          const node = e.target.closest("[data-trace-id]");
          if (!node) return;

          const detailId = "detail-" + node.dataset.traceId;
          const detail = ctx.root.querySelector("#" + CSS.escape(detailId));
          if (detail) {
            detail.style.display = detail.style.display === "none" ? "block" : "none";
            const toggle = node.querySelector(".toggle");
            if (toggle) toggle.textContent = detail.style.display === "none" ? "▶" : "▼";
          }
        });
      }

      function renderRoot(data) {
        const nodes = data.nodes || [];
        if (nodes.length === 0) return '<div style="color:#808080;padding:16px;">No trace data available</div>';

        return `
          <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;font-size:13px;background:#1e1e1e;color:#d4d4d4;border-radius:8px;padding:16px;line-height:1.5;">
            <div style="font-size:14px;color:#808080;margin-bottom:12px;font-weight:500;">Agent Hierarchy</div>
            ${renderNodes(nodes, 0)}
          </div>
        `;
      }

      function renderNodes(nodes, depth) {
        return nodes.map(n => renderNode(n, depth)).join("");
      }

      function renderNode(node, depth) {
        const indent = depth * 20;
        const hasChildren = node.children && node.children.length > 0;
        const hasDetail = node.turns && node.turns.length > 0;
        const toggleChar = (hasChildren || hasDetail) ? "▶" : "•";
        const prefix = depth > 0 ? (node === node ? "├─ " : "├─ ") : "";

        const badges = [];
        if (node.duration_ms != null) badges.push(formatDuration(node.duration_ms));
        if (node.total_tokens) badges.push(node.total_tokens + " tk");
        if (node.turn_count) badges.push(node.turn_count + " turns");

        const badgeHtml = badges.map(b =>
          `<span style="font-size:11px;color:#808080;background:#1e1e1e;padding:1px 6px;border-radius:3px;margin-left:6px;">${b}</span>`
        ).join("");

        const statusColor = node.failed ? "#f44747" : "#4ec9b0";
        const statusDot = `<span style="display:inline-block;width:6px;height:6px;border-radius:50%;background:${statusColor};margin-right:6px;"></span>`;

        const detailHtml = hasDetail ? renderDetail(node) : "";
        const childrenHtml = hasChildren ? renderNodes(node.children, depth + 1) : "";

        return `
          <div style="padding-left:${indent}px;">
            <div data-trace-id="${node.trace_id || node.name}" style="display:flex;align-items:center;gap:4px;padding:4px 8px;border-radius:4px;cursor:pointer;user-select:none;" onmouseover="this.style.background='#2d2d2d'" onmouseout="this.style.background='transparent'">
              <span class="toggle" style="font-size:10px;color:#808080;width:14px;text-align:center;">${toggleChar}</span>
              ${statusDot}
              <span style="font-weight:500;">${escHtml(node.name)}</span>
              ${badgeHtml}
            </div>
            <div id="detail-${node.trace_id || node.name}" style="display:none;padding-left:${indent + 28}px;margin-bottom:8px;">
              ${detailHtml}
            </div>
            ${childrenHtml}
          </div>
        `;
      }

      function renderDetail(node) {
        if (!node.turns || node.turns.length === 0) return "";

        return node.turns.map((turn, i) => {
          const parts = [];
          const secStyle = "margin-top:6px;";
          const labelStyle = "color:#808080;font-size:11px;text-transform:uppercase;font-weight:600;";
          const preStyle = "background:#1e1e1e;border-radius:4px;padding:8px;margin:4px 0;font-size:12px;overflow-x:auto;white-space:pre-wrap;border:1px solid #3c3c3c;max-height:300px;overflow-y:auto;";

          // Messages (input to LLM, excluding system)
          if (turn.messages && turn.messages.length > 0) {
            const msgHtml = turn.messages.map(m =>
              `<div style="margin:4px 0;"><span style="color:#c586c0;font-size:11px;">${escHtml(m.role)}</span><pre style="${preStyle}">${escHtml(m.content)}</pre></div>`
            ).join("");
            parts.push(`<div style="${secStyle}"><details><summary style="${labelStyle}cursor:pointer;">INPUT MESSAGES (${turn.messages.length})</summary>${msgHtml}</details></div>`);
          }

          // Raw response (LLM output including reasoning)
          if (turn.raw_response) {
            parts.push(`<div style="${secStyle}"><details><summary style="${labelStyle}cursor:pointer;">RAW RESPONSE</summary><pre style="${preStyle}color:#6a9955;">${escHtml(turn.raw_response)}</pre></details></div>`);
          }

          // Program
          if (turn.program) {
            parts.push(`<div style="${secStyle}"><span style="${labelStyle}">PROGRAM</span><pre style="${preStyle}">${escHtml(turn.program)}</pre></div>`);
          }

          // Tool calls with args and results
          if (turn.tool_calls && turn.tool_calls.length > 0) {
            const toolHtml = turn.tool_calls.map(tc => {
              let detail = `<div style="padding:4px 0;"><span style="color:#dcdcaa;font-weight:500;">${escHtml(tc.name)}</span> <span style="color:#808080;">${formatDuration(tc.duration_ms)}</span>${tc.error ? `<span style="color:#f44747;margin-left:8px;">error: ${escHtml(tc.error)}</span>` : ""}`;
              if (tc.args) detail += `<pre style="${preStyle}font-size:11px;max-height:150px;"><span style="color:#808080;">args:</span> ${escHtml(tc.args)}</pre>`;
              if (tc.result) detail += `<pre style="${preStyle}font-size:11px;max-height:150px;"><span style="color:#808080;">result:</span> ${escHtml(tc.result)}</pre>`;
              detail += `</div>`;
              return detail;
            }).join("");
            parts.push(`<div style="${secStyle}"><span style="${labelStyle}">TOOLS</span>${toolHtml}</div>`);
          }

          // Prints
          if (turn.prints && turn.prints.length > 0) {
            parts.push(`<div style="${secStyle}"><span style="${labelStyle}">PRINTS</span><pre style="${preStyle}color:#ce9178;">${escHtml(turn.prints.join("\\n"))}</pre></div>`);
          }

          // Result
          if (turn.result) {
            parts.push(`<div style="${secStyle}"><span style="${labelStyle}">RESULT</span><pre style="${preStyle}">${escHtml(turn.result)}</pre></div>`);
          }

          // Error
          if (turn.error) {
            parts.push(`<div style="${secStyle}color:#f44747;"><span style="${labelStyle}">ERROR</span><pre style="background:rgba(244,71,71,0.1);border-radius:4px;padding:8px;margin:4px 0;font-size:12px;">${escHtml(turn.error)}</pre></div>`);
          }

          const turnNum = turn.number || (i + 1);
          const typeLabel = turn.type && turn.type !== "normal" ? ` <span style="color:#c586c0;font-size:11px;">[${turn.type}]</span>` : "";
          const successIcon = turn.success === false ? '<span style="color:#f44747;margin-left:6px;">FAIL</span>' : "";

          return `
            <div style="border-left:2px solid #3c3c3c;padding-left:12px;margin:6px 0;">
              <div style="color:#569cd6;font-size:12px;font-weight:500;">Turn ${turnNum}${typeLabel}${successIcon}</div>
              ${parts.join("")}
            </div>
          `;
        }).join("");
      }

      function formatDuration(ms) {
        if (ms == null) return "-";
        if (ms < 1000) return ms + "ms";
        if (ms < 60000) return (ms / 1000).toFixed(1) + "s";
        return (ms / 60000).toFixed(1) + "m";
      }

      function escHtml(text) {
        if (!text) return "";
        const d = document.createElement("div");
        d.textContent = text;
        return d.innerHTML;
      }
      """
    end

    asset "main.css" do
      ""
    end

    # Build a recursive node from a single Step using child_steps
    defp build_node(%PtcRunner.Step{} = step) do
      node = step_to_node(step)
      children = Enum.map(step.child_steps || [], &build_node/1)
      %{node | children: children}
    end

    # Build tree data from list of Steps (flat list, uses link_children for parent_trace_id linking)
    defp build_tree(steps) do
      nodes =
        steps
        |> Enum.map(&step_to_node/1)
        |> link_children()

      %{nodes: nodes}
    end

    defp step_to_node(%PtcRunner.Step{} = step) do
      turns = extract_turns(step)

      %{
        trace_id: step.trace_id || random_id(),
        parent_trace_id: step.parent_trace_id,
        name: extract_name(step),
        duration_ms: step.usage && step.usage[:duration_ms],
        total_tokens: step.usage && step.usage[:total_tokens],
        turn_count: step.usage && step.usage[:turns],
        failed: step.fail != nil,
        fail_reason: step.fail && step.fail[:reason],
        turns: turns,
        children: [],
        child_trace_ids: step.child_traces || []
      }
    end

    defp extract_name(%PtcRunner.Step{} = step) do
      cond do
        step.name && step.name != "" ->
          step.name

        step.prompt && String.length(step.prompt) > 0 ->
          step.prompt |> String.slice(0, 40) |> String.trim()

        step.trace_id ->
          "agent_#{String.slice(step.trace_id, 0, 8)}"

        true ->
          "agent"
      end
    end

    defp extract_turns(%PtcRunner.Step{turns: nil}), do: []

    defp extract_turns(%PtcRunner.Step{turns: turns}) when is_list(turns) do
      Enum.map(turns, fn turn ->
        %{
          number: Map.get(turn, :number),
          type: to_string(Map.get(turn, :type, :normal)),
          program: Map.get(turn, :program) || Map.get(turn, :code),
          raw_response: extract_raw_response(turn),
          messages: extract_messages(turn),
          result: truncate_string(inspect_safe(Map.get(turn, :result)), 2000),
          prints: Map.get(turn, :prints) || [],
          tool_calls: extract_tool_calls(turn),
          success: Map.get(turn, :success?),
          error: extract_turn_error(turn)
        }
      end)
    end

    defp extract_raw_response(turn) do
      case Map.get(turn, :raw_response) do
        nil -> nil
        resp when is_binary(resp) -> truncate_string(resp, 4000)
        _ -> nil
      end
    end

    defp extract_messages(turn) do
      case Map.get(turn, :messages) do
        nil ->
          []

        msgs when is_list(msgs) ->
          msgs
          |> Enum.reject(fn m -> m[:role] == :system end)
          |> Enum.map(fn m ->
            %{
              role: to_string(m[:role] || "unknown"),
              content: truncate_string(to_string(m[:content] || ""), 2000)
            }
          end)
      end
    end

    defp extract_tool_calls(turn) do
      calls = Map.get(turn, :tool_calls) || []

      Enum.map(calls, fn tc ->
        %{
          name: tc[:name] || "unknown",
          args: truncate_string(inspect_safe(tc[:args]), 500),
          result: truncate_string(inspect_safe(tc[:result]), 1000),
          duration_ms: tc[:duration_ms],
          error: tc[:error]
        }
      end)
    end

    defp extract_turn_error(turn) do
      cond do
        Map.has_key?(turn, :error) && turn.error -> inspect(turn.error)
        Map.has_key?(turn, :fail) && turn.fail -> inspect(turn.fail)
        true -> nil
      end
    end

    defp inspect_safe(nil), do: nil
    defp inspect_safe(val) when is_binary(val), do: val
    defp inspect_safe(val), do: inspect(val, limit: 20, printable_limit: 2000)

    defp truncate_string(nil, _), do: nil
    defp truncate_string(str, max) when byte_size(str) <= max, do: str
    defp truncate_string(str, max), do: String.slice(str, 0, max) <> "..."

    defp link_children(nodes) do
      by_trace_id = Map.new(nodes, &{&1.trace_id, &1})

      {roots, children_map} =
        Enum.reduce(nodes, {[], %{}}, fn node, {roots, cm} ->
          if node.parent_trace_id && Map.has_key?(by_trace_id, node.parent_trace_id) do
            existing = Map.get(cm, node.parent_trace_id, [])
            {roots, Map.put(cm, node.parent_trace_id, [node | existing])}
          else
            {[node | roots], cm}
          end
        end)

      roots
      |> Enum.reverse()
      |> Enum.map(&attach_children(&1, children_map))
    end

    defp attach_children(node, children_map) do
      children =
        children_map
        |> Map.get(node.trace_id, [])
        |> Enum.reverse()
        |> Enum.map(&attach_children(&1, children_map))

      %{node | children: children}
    end

    defp random_id do
      :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    end
  end
end
