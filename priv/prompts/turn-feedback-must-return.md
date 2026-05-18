# Must Return Warning

Warning shown when entering must-return mode (final work turn).

Context variables:
- `has_retries`: boolean, whether retry turns are available
- `retry_count`: integer, number of retry turns remaining

<!-- version: 2 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: turn-feedback-message -->
<!-- budget: target<=1000 bytes, hard<=1500 bytes -->
<!-- changes: Removed auto_return conditionals — only explicit return mode remains -->
<!-- variables: has_retries, retry_count -->

<!-- PTC_PROMPT_START -->
{{#has_retries}}
FINAL WORK TURN - tools stripped, you must call (return result) or (fail response). If your response has errors, you will have {{retry_count}} correction attempt(s).
{{/has_retries}}
{{^has_retries}}
FINAL WORK TURN - tools stripped, you must call (return result) or (fail response).
{{/has_retries}}
<!-- PTC_PROMPT_END -->
