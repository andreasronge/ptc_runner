# Tool Calling System Prompt

System prompt for tool calling output mode.

<!-- version: 1 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: text-mode-tool-calling-system-prompt -->
<!-- budget: target<=1000 bytes, hard<=1500 bytes -->
<!-- used-by: PtcRunner.SubAgent.Loop.TextMode -->
<!-- profiles: text output mode with provider-native tool calling -->
<!-- shown-in: provider system message for native tool-calling text mode -->
<!-- composed-with: output instruction appended in code -->

<!-- PTC_PROMPT_START -->

<role>
Use tools to complete the task.
</role>

<instructions>
- Call tools when needed.
- Final answer: raw JSON object matching the expected output. No markdown, no explanation.
</instructions>

<!-- PTC_PROMPT_END -->
