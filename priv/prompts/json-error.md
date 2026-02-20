# JSON Mode Error Feedback

Error feedback for JSON validation failures.

<!-- version: 2 -->
<!-- date: 2026-02-18 -->
<!-- changes: Wrap in XML tag -->

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
