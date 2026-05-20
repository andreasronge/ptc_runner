# Text Mode (JSON variant) System Prompt

System prompt for text mode structured JSON output.

<!-- version: 2 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: text-mode-json-system-prompt -->
<!-- budget: target<=1000 bytes, hard<=1500 bytes -->
<!-- changes: Wrap in XML tag -->
<!-- used-by: PtcRunner.SubAgent.Loop.TextMode -->
<!-- profiles: text output mode, JSON variant -->
<!-- shown-in: provider system message unless a custom system prompt replaces it -->
<!-- composed-with: json-user.md user message; json-error.md on retry -->

<!-- PTC_PROMPT_START -->

<output_format>
Return only valid structured JSON matching the expected format. No markdown, no explanation.
</output_format>

<!-- PTC_PROMPT_END -->
