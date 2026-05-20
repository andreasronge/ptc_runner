# PTC-Lisp Single-Shot Behavior

Rules for single-shot execution (one turn, no memory).

<!-- version: 1 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: ptc-lisp-system-prompt -->
<!-- budget: target<=1000 bytes, hard<=1500 bytes -->
<!-- changes: Renamed from lisp-addon-single_shot.md as part of 2-axis prompt refactor -->
<!-- used-by: PtcRunner.Lisp.LanguageSpec via PtcRunner.Lisp.PromptRegistry -->
<!-- profiles: single_shot -->
<!-- shown-in: SubAgent PTC-Lisp system prompt for one-turn/single-shot profiles -->
<!-- composed-with: reference.md before this card -->

<!-- PTC_PROMPT_START -->

<single_shot>
Respond with EXACTLY ONE ```clojure code block. The last expression's value IS your answer.

```clojure
(->> data/products
     (filter #(= (:category %) "electronics"))
     (count))
```
</single_shot>

<!-- PTC_PROMPT_END -->
