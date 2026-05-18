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
Your response was not valid JSON or didn't match the expected format.

Error: {{error_message}}

Your response was:
{{invalid_response}}

Please return valid JSON matching this format:
{{expected_format}}
</error_feedback>

<!-- PTC_PROMPT_END -->
