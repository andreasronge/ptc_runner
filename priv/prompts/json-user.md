# JSON Mode User Message Template

User message template for JSON output mode.

<!-- version: 2 -->
<!-- date: 2026-01-22 -->
<!-- changes: Removed Data section - data is embedded via mustache in task -->

<!-- PTC_PROMPT_START -->

# Task

{{task}}

# Expected Output

{{output_instruction}}
{{field_descriptions}}

Example format:
```json
{{example_output}}
```

<!-- PTC_PROMPT_END -->
