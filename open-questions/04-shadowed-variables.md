# How to show shadowed variables and compiler temporaries?

**Already built:** each frame has two scopes. "Locals" shows the latest
binding of each Gleam variable under its Gleam name and hides compiler
temporaries. "Raw bindings" (collapsed, marked expensive) shows every
binding under its Erlang name: `X`, `X@1`, `_pipe`, `_use0`.

## Where and when it came up

Step 3 of PLAN.md: "When a variable is shadowed, show only the latest binding
by default, with older ones in a collapsed 'shadowed' group" and "Hide
compiler temporaries such as `_pipe` and `_use0`, or group them". It came up
in `inspect.variables_body` and `names.latest_bindings`.

## What I chose

The second scope, "Raw bindings", instead of a "shadowed" group inside
"Locals".

## Options

### A. "Locals" plus "Raw bindings" scopes (chosen)

- "Locals" reads like Gleam source: one `x`, its current value.
- Everything else, old versions and temporaries, is one click away in a
  scope that's collapsed by default, under the names the compiler really
  used, which also helps when reading the generated code or a crash report.
- The older versions aren't labelled "shadowed"; you recognise them by the
  `@N` suffix.

### B. A "shadowed" group inside "Locals", temporaries hidden

- Exactly what the plan describes.
- A synthetic variable in the list of locals: in VS Code it looks like a
  variable named "shadowed", and watch/hover/evaluate can't refer to it.
- Temporaries would be invisible, though they sometimes hold the
  interesting value (the value being piped).

### C. Show everything with Gleam names and a version suffix

- No hidden information.
- `x`, `x (1)`, `x (2)` and every `_pipe` crowd the view in pipeline-heavy
  code.

## Why

A keeps "Locals" as clean as B and loses nothing, using a standard DAP
feature (scopes) instead of a fake variable.

## How to change it

`scopes_body` and `variables_body` in `src/gleam_dap/inspect.gleam`. A
"shadowed" group would be a `ValueRef` pointing at the older bindings,
appended to the `Locals` list.
