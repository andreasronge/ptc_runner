# Retry Feedback

Turn info shown during retry phase after a failed return attempt.

Context variables:
- `is_final_retry`: boolean, whether this is the last retry
- `current_retry`: integer, current retry attempt number (1-based)
- `total_retries`: integer, total number of retry attempts configured
- `retries_remaining`: integer, number of retry attempts left
- `next_turn`: integer, the next turn number

<!-- version: 1 -->
<!-- date: 2026-01-24 -->
<!-- changes: Initial version -->

<!-- PTC_PROMPT_START -->
{{#is_final_retry}}
FINAL RETRY (Retry {{current_retry}} of {{total_retries}}) - you must call (return result) or (fail response) next.
{{/is_final_retry}}
{{^is_final_retry}}
Turn {{next_turn}}: Retry {{current_retry}} of {{total_retries}} ({{retries_remaining}} retries remaining)
{{/is_final_retry}}
<!-- PTC_PROMPT_END -->
