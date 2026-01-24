# Must Return Warning

Warning shown when entering must-return mode (final work turn).

Context variables:
- `has_retries`: boolean, whether retry turns are available
- `retry_count`: integer, number of retry turns remaining

<!-- version: 1 -->
<!-- date: 2026-01-24 -->
<!-- changes: Initial version -->

<!-- PTC_PROMPT_START -->
{{#has_retries}}
FINAL WORK TURN - tools stripped, you must call (return result) or (fail response). If your response has errors, you will have {{retry_count}} correction attempt(s).
{{/has_retries}}
{{^has_retries}}
FINAL WORK TURN - tools stripped, you must call (return result) or (fail response).
{{/has_retries}}
<!-- PTC_PROMPT_END -->
