# Read and write PTC-Lisp

> **Audience:** anyone meeting PTC-Lisp for the first time — to read what a
> model wrote in a trace, or to try the language by hand before building
> anything.

PTC-Lisp is the small, bounded, Clojure-like language the model writes its
mission programs in. You can learn to read it in ten minutes, and the fastest
way is to type it. This page is a tour; the
[language specification](../ptc-lisp-specification.md) is the contract, and the
[function reference](../function-reference.md) lists everything callable.

Every example below is validated against the interpreter, so what you see is
what the runtime returns.

## Open a REPL

```console
ptc repl
```

Type an expression, get a value back:

```console
PTC-Lisp REPL (:quit to exit; :help for commands)
ptc> (+ 1 2)
3
ptc> (str "tick" "-" "tock")
"tick-tock"
```

A REPL session keeps state: what one input defines, the next input can use —
the same way the model works across turns, narrowing a problem step by step.

## Values are JSON values

PTC-Lisp data is JSON-shaped: numbers, strings, booleans, `nil`, vectors, and
maps. Literals evaluate to themselves:

```clojure
42            ; => 42
"hello"       ; => "hello"
true          ; => true
[1 2 3]       ; => [1 2 3]
{"name" "Ada"} ; => {"name" "Ada"}
```

Map keys are strings. Keywords like `:name` are a shorthand you will see
everywhere in generated code — writing a keyword key stores the string key:

```clojure
(assoc {"a" 1} :b 2) ; => {"a" 1 "b" 2}
```

## Call functions

A call is a list: the function first, then its arguments. There is no other
syntax to learn.

```clojure
(+ 1 2)          ; => 3
(count [1 2 3])  ; => 3
(str "a" "b")    ; => "ab"
```

The REPL can describe any function for you:

```console
ptc> (doc "str")
(str ...)
  Convert and concatenate to string
```

## Name things

`def` names a value for the whole session; `let` names values for one
expression:

```console
ptc> (def answer 42)
#'answer
ptc> answer
42
```

```clojure
(let [a 2
      b 3]
  (* a b)) ; => 6
```

Nothing is ever reassigned. Functions return new values and leave their
arguments untouched — `assoc` above returned a new map.

## Reach into maps

```clojure
(get {"name" "Ada"} "name")                        ; => "Ada"
(:name {"name" "Ada"})                             ; => "Ada"
(get-in {"user" {"name" "Ada"}} ["user" "name"])   ; => "Ada"
```

A keyword in the function position looks itself up, and string and keyword
access are interchangeable — generated code uses both.

## Transform collections

`map`, `filter`, and `reduce` do most of the work in mission programs:

```clojure
(map inc [1 2 3])           ; => [2 3 4]
(filter odd? [1 2 3 4 5])   ; => [1 3 5]
(reduce + [1 2 3 4])        ; => 10
```

The threading macro `->>` chains steps in reading order — this is the shape
most generated programs take:

```clojure
(->> [1 2 3 4 5]
     (filter odd?)
     (map (fn [n] (* n n)))
     (reduce +)) ; => 35
```

## Decide

`nil` and `false` are falsy; everything else, including `0` and `""`, is
truthy:

```clojure
(if (> 3 2) "yes" "no") ; => "yes"
(if 0 "truthy" "falsy") ; => "truthy"
(nil? nil)              ; => true
```

## Mistakes are values

Where many languages raise, the sandbox returns a recoverable error value and
the session continues:

```console
ptc> (/ 1 0)
Error (arithmetic_error): arithmetic_error: division by zero
ptc> (+ 1 2)
3
```

This is deliberate: a mistake costs the model one expression, not the run.
The [Clojure conformance gaps](../clojure-conformance-gaps.md) reference
records every place this value model diverges from Clojure, with rationale.

## Define functions

`defn` defines a named function. In a REPL session it persists across inputs;
in one expression, group the definition and the call with `do`:

```clojure
(do
  (defn double [n] (* 2 n))
  (double 21)) ; => 42
```

Anonymous functions are `(fn [n] ...)`, as in the threading example above.

## Where to go next

- [Explore a project interactively](kernel-repl.md) — the REPL against a real
  project: its data, components, and missions.
- [Understand a generated project](getting-started.md) — where PTC-Lisp sits
  inside a runnable application.
- [PTC-Lisp specification](../ptc-lisp-specification.md) — the full language,
  with every example validated.
- [Function reference](../function-reference.md) — everything callable, by
  section.
