# How is the Gleam expression evaluator built?

**Already built (PR #5):** `src/gleam_dap_gleam_eval.erl` is a Gleam front
end: a lexer and a precedence-climbing parser for Gleam expressions and
statements, and a translation to Erlang abstract syntax that `erl_eval`
runs with the stopped frame's bindings. Input that fails to parse as Gleam
is tried with the older Erlang path (see
[05-debug-console-language.md](05-debug-console-language.md)); if that
fails too, the Gleam error is shown.

## Where and when it came up

Closing the gaps with ElixirLS, whose console evaluates real Elixir with
`Code.eval_string`. The Gleam compiler isn't available inside the VM.

## What it covers

Literals (all number forms, strings with escapes, lists with spread,
tuples, bit arrays with segment options), variables by Gleam name, record
constructors with and without labels (`Person(name: "Ada", age: 36)`,
`option.Some(1)`), record updates, every operator with Gleam's precedence
and semantics (integer `/` and `%` return 0 for 0, float operators, `<>`),
pipes including `_` captures, field and tuple-index access, module calls,
calls to the frame module's public functions without a module name,
anonymous functions with typed parameters, blocks, `let`, `let assert`, and
`case` with multiple subjects, alternatives, guards, string-prefix patterns,
`as`, and record patterns with labels and `..`.

## Choices inside it

- **Written in Erlang, not Gleam.** It produces Erlang abstract syntax
  tuples throughout, which in Gleam would need an untyped FFI layer for
  every node. Erlang keeps it in one file next to the evaluator it feeds.
- **No type checking.** Types would need every module's type information
  (Gleam's `.cache` files have it, but in an unstable format). A wrong
  expression fails when it runs, with the runtime error.
- **Labelled arguments only for constructors.** Constructor labels come from
  the record headers Gleam generates; function labels aren't kept anywhere
  in compiled code. A labelled function call is refused with a message
  rather than guessed, since guessing the order could silently compute
  something else.
- **Guards can do anything.** Gleam guards allow field access, which Erlang
  guards don't. A `case` with a guard is compiled to a chain of funs that
  try each clause and fall through, instead of an Erlang `case`.
- **Unqualified calls go to the frame's module**, public functions only
  (private ones aren't callable from outside the module).
- **`use` is refused**, since it needs the rest of a block as a callback and
  rarely makes sense in a console.
- **Erlang fallback kept**, so `erlang:length(xs)` and raw names such as
  `X@1` keep working.

## Options for the whole approach

### A. A Gleam front end translating to `erl_eval` (chosen)

- Real Gleam syntax and semantics for everything people type in a debugger.
- No types, as above.

### B. Compile each expression with the Gleam compiler

- Write the expression into a scratch module and run `gleam build` on it.
- Exact semantics and type errors, but takes a second or more per
  evaluation, needs a writable project copy, and can't see the frame's
  bindings without generating a function with every variable as a typed
  parameter, whose types aren't known at runtime.

### C. Keep Erlang with a Gleam layer

- Already there; no pipes, `case` or `fn`.

## Why

A gives Gleam in the console at interactive speed. B would be the way to
get type checking, at a cost that doesn't suit watches and hovers.

## How to change it

`compile/3` is the entry point; `eval_now/3` in
`src/gleam_dap_eval_ffi.erl` decides between Gleam and the Erlang fallback.
The unit tests are in `test/eval_test.gleam`.
