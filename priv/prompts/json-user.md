# Text Mode (JSON variant) User Message Template

User message template for text mode structured JSON output.

<!-- version: 3 -->
<!-- date: 2026-02-18 -->
<!-- changes: Wrap sections in XML tags -->

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
