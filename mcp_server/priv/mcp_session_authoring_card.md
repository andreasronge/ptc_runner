# PTC-Lisp sessions

This tool evaluates PTC-Lisp inside a stateful session. Values defined
with `(def name value)` and functions defined with `(defn name [args]
body)` are available in later `ptc_session_eval` calls for the same
session.

Use `println` to inspect values between calls. Printed lines are
captured and returned; they are not stdout.

`*1`, `*2`, and `*3` reference the last three successful eval results.

Use `let` for temporary values. Use `ptc_session_forget` to remove
stale or large bindings.

Keep programs short and store only values you need again.
