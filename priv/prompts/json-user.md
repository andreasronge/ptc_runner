# Text Mode (JSON variant) User Message Template

User message template for text mode structured JSON output.

<!-- version: 3 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: text-mode-json-user-message -->
<!-- budget: target<=1000 bytes, hard<=1500 bytes -->
<!-- changes: Wrap sections in XML tags -->
<!-- variables: task, output_instruction, field_descriptions -->

<!-- PTC_PROMPT_START -->

<task>
{{task}}
</task>

<expected_output>
{{output_instruction}}
{{field_descriptions}}

Example format:
```json
{{example_output}}
```
</expected_output>

<!-- PTC_PROMPT_END -->
