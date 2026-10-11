# How to ship and implement `debug.break()`?

**Already built:** a separate Gleam package in `packages/gleam_dap_debug`
with `gleam_dap/debug.break()`, used as a path dependency. Its FFI checks
whether the debug session is running (`whereis(gleam_dap_session)`) and, if
so, calls `stop_here/0`. The adapter interprets that FFI module, keeps a
breakpoint in `stop_here`, and when a process stops there it runs `finish`
and reports the stop on the caller's next line, with reason `breakpoint`.

## Where and when it came up

Step 5 of PLAN.md lists "A `debug.break()` function to stop from code", and
[docs/elixirls-features.md](../docs/elixirls-features.md) sketches it as "a
tiny function in an FFI module that calls the adapter and waits until the
user continues". It came up when implementing it: a function that sends a
message to the adapter and blocks can't be inspected like a breakpoint,
because the process isn't stopped by `int`, so variables, stepping and the
stack trace wouldn't work from there.

## What I chose

Make `break()` a real `int` breakpoint, as described above, so everything
that works at a breakpoint works after `debug.break()`, including stepping
on from there.

## Options

### A. Interpreted FFI module plus breakpoint plus finish (chosen)

- The stop is indistinguishable from a breakpoint on the next line.
- Outside the debugger it's a `whereis` and a return: nearly free.
- Only works in interpreted callers: from compiled code, `finish` has no
  interpreted caller to return to. That's documented.

### B. Block in the FFI until the adapter says continue

- The plan's sketch; works from any code, interpreted or not.
- No variables, stack or stepping at the stop; it's only a pause.

### C. Hook Gleam's `echo` as well

- `echo` is already in people's code while debugging.
- Changes what a language feature does, and `echo` is often left in for
  printing; stopping on every one would be surprising. Left open.

### Packaging: separate path-dependency package (chosen) vs. publishing to Hex vs. a module inside the adapter

- A path dependency works today and needs nobody's approval.
- Publishing to Hex would make `gleam add gleam_dap_debug` work, but this is
  a personal tool (see PLAN.md) and publishing is outward-facing.
- A module inside the adapter can't be imported by the user's project.

## Why

A gives the full debugging experience at the stop with very little code.
The path dependency keeps everything in this repository.

## How to change it

`packages/gleam_dap_debug/src/gleam_dap_debug_ffi.erl` and
`setup_debug_break` plus the `DebugBreak` stepping case in
`src/gleam_dap/session.gleam`. To publish, add the Hex metadata to the
package's `gleam.toml` and run `gleam publish` there.
