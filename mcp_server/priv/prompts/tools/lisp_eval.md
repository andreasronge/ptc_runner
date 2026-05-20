# lisp_eval

Composed with: `../reference.md` after this card.

<!-- PTC_PROMPT_START -->
One stateless PTC-Lisp program. Final value = result. Use `println` briefly to inspect shapes.
Context: `{"items":[...]}` -> `data/items`; no `context` binding.
Example: `{"records":[{"name":"a"}]}` -> `(get (first data/records) "name")`; no `context`.
Fail: `(fail v)`. No persistence across calls.
<!-- PTC_PROMPT_END -->
