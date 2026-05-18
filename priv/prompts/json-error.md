# Text Mode (JSON variant) Error Feedback

Error feedback for text mode JSON validation failures.

<!-- version: 2 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: text-mode-json-error-feedback -->
<!-- budget: target<=1000 bytes, hard<=1500 bytes -->
<!-- changes: Wrap in XML tag -->
<!-- variables: error_message, invalid_response -->

<!-- PTC_PROMPT_START -->

<error_feedback>
Invalid JSON or wrong shape.

Error: {{error_message}}

Response:
{{invalid_response}}

Return valid JSON matching:
{{expected_format}}
</error_feedback>

<!-- PTC_PROMPT_END -->
