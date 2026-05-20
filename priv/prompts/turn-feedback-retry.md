# Retry Feedback

Turn info shown during retry phase after a failed return attempt.

Context variables:
- `is_final_retry`: boolean, whether this is the last retry
- `current_retry`: integer, current retry attempt number (1-based)
- `total_retries`: integer, total number of retry attempts configured
- `retries_remaining`: integer, number of retry attempts left
- `next_turn`: integer, the next turn number

<!-- version: 1 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: turn-feedback-message -->
<!-- budget: target<=1000 bytes, hard<=1500 bytes -->
<!-- changes: Initial version -->
<!-- variables: is_final_retry, current_retry, total_retries, retries_remaining, next_turn -->
<!-- used-by: PtcRunner.SubAgent.Loop.TurnFeedback -->
<!-- profiles: explicit return retry phase -->
<!-- shown-in: provider user feedback message after failed return validation -->
<!-- composed-with: validation feedback and retry counters supplied by code -->

<!-- PTC_PROMPT_START -->
{{#is_final_retry}}
FINAL RETRY {{current_retry}}/{{total_retries}}: call `(return result)` or `(fail response)`.
{{/is_final_retry}}
{{^is_final_retry}}
Turn {{next_turn}} retry {{current_retry}}/{{total_retries}}; {{retries_remaining}} left.
{{/is_final_retry}}
<!-- PTC_PROMPT_END -->
