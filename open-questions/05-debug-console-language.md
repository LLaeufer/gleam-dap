# What language does the debug console speak?

**Already built:** first Erlang with a Gleam layer (option A, in PR #4),
now real Gleam expressions (option C, in PR #5): see
[23-gleam-evaluator.md](23-gleam-evaluator.md) for how the Gleam front end
was built. The Erlang path below stays as the fallback for input that isn't
Gleam. The same evaluator runs watches, hovers, breakpoint conditions and
logpoint `{...}` parts.

## Where and when it came up

Step 5 of PLAN.md: "Evaluate in the debug console, watch and hover: variable
and field lookups first, then Erlang expressions", and conditions "with
Erlang expressions at first".

## What I chose

The input is tokenised as Erlang, then rewritten:

- lowercase names that are variables become the latest Erlang binding
  (`x` to `X@2`); unknown lowercase names give "Unknown variable x";
- `True`, `False`, `Nil` become atoms; string literals become UTF-8
  binaries;
- `<>`, `!=`, `&&`, `||` become their Erlang counterparts (`<>` works on
  strings and lists);
- `a.label` and `a.0` become field access, using the record headers;
- `module.function(...)` becomes a call to the loaded Gleam module
  (`string` to `gleam@string`, `flow` to `sample@flow`).

Everything else is plain Erlang (`erlang:length(xs)` works too). Evaluation
runs in a separate process with a 5 second timeout.

## Options

### A. Erlang with a Gleam layer (chosen)

- What people type in a debugger (variables, fields, comparisons, calls)
  reads like Gleam.
- Small: a token rewriter on top of `erl_eval`.
- Pipes, `case`, `fn`, `let` and record construction don't work; when they
  are typed, the error comes from the Erlang parser.

### B. Plain Erlang only

- Simplest; no surprises for Erlang users.
- Users would have to know Gleam's compiled names (`X@1`, `<<"str">>`,
  `element(3, P)`), which defeats the point of a Gleam debugger.

### C. Real Gleam expressions

- The ideal.
- Needs a Gleam expression parser and a translation to Erlang (or the Gleam
  compiler at runtime, which isn't available as a library). Type checking
  would need the module's types. Much bigger than the rest of the evaluator.

## Why

A covered the common cases cheaply and left C open. C was built later to
close the gap with ElixirLS, which evaluates real Elixir. The plan already
expected Erlang expressions at first.

## How to change it

`tokens/2`, `rewrite/2` and `rewrite_operators/1` in
`src/gleam_dap_eval_ffi.erl`. A Gleam front end would produce Erlang
abstract syntax for `erl_eval` the same way.
