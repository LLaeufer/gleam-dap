# How do conditions and stepping work when attached?

**Already built (PR #5):** when attached to a node, the generated
`gleam_dap_conditions` module is loaded on that node too, and each of its
`check_N/1` functions reads the debugged process and its call level where
it runs, then calls `gleam_dap_eval_ffi:check/4` on the adapter's node with
`erpc`. The condition tables, the evaluator and the logpoint output all stay
in the adapter. On detach the module is removed from the node again.
Targeted step over and step out (see [06-stepping.md](06-stepping.md)) are
now used in attach mode as well.

## Where and when it came up

Closing the gaps with ElixirLS. Before, attaching fell back to `int`'s own
`next`/`finish`, and conditions silently never held, because `int` calls
breakpoint conditions in the meta process, which lives on the node of the
debugged process, where neither the conditions module nor its tables
existed.

## Options

### A. Load the module on the node, call back to the adapter (chosen)

- Only one small generated module goes to the node, nothing of the
  adapter. The tables and callbacks keep living in one place.
- Each check of a conditional or temporary breakpoint costs a round trip to
  the adapter. Plain breakpoints don't have a condition, so they cost
  nothing extra.
- If the adapter disappears mid-check, the call fails and the condition is
  false, so the node keeps running.

### B. Load the adapter's evaluator and tables onto the node

- No round trips.
- Copies several adapter modules (and, from a source checkout, the
  adapter's `gleam_stdlib`) onto someone's running node, where they might
  clash with the node's own copies; the tables would need syncing.

### C. Keep the fallback

- No new code; breakpoints inside stepped calls and conditions don't work
  when attached.

## Why

A makes attach behave like launch with the least footprint on the node.

## Details worth knowing

Conditions and logpoint expressions are evaluated on the adapter's node. A
condition that calls a function (`list.length(xs) > 2`) runs the adapter's
copy of that module, which for a project's own modules is the same code;
the README lists it as a limitation.

## How to change it

`condition_forms/2`, `set_remote/1` and `unload_remote/0` in
`src/gleam_dap_eval_ffi.erl`; `targeted_steps` in
`src/gleam_dap/session.gleam` decides when targeted steps are used.
