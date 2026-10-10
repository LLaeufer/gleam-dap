# When to stop on crashes?

**Already built:** two exception filters, "Gleam errors" (`gleam`, on by
default) and "All crashes" (`all`, off by default). A stop on a crash shows
the error in `exceptionInfo` and keeps the crashed process's variables
readable until you continue.

## Where and when it came up

Step 3 of PLAN.md: "Stop on uncaught Gleam errors (`panic`, `todo`,
`let assert`) using `int:auto_attach([exit], ...)`", and
[docs/elixirls-features.md](../docs/elixirls-features.md) proposes the two
filters. ElixirLS itself has no exception breakpoints. The open parts came up
when deciding whether non-Gleam crashes (`badarg`, `function_clause` in Erlang
FFI, exits) should stop too, and how a process that is already exiting can
still be inspected.

## What I chose

- When an interpreted process exits abnormally, the adapter attaches to it
  (`int:attached`), which keeps its bindings available, and reports a
  `stopped` event with reason `exception`.
- With "Gleam errors", only errors whose reason is a Gleam error map stop;
  the description reads like `let assert failed: <message>` and includes the
  value that didn't match.
- With "All crashes", any abnormal exit stops.
- Normal exits and `shutdown` exits never stop.
- Continuing lets the process finish exiting.

## Options

### A. Gleam errors by default, all crashes opt-in (chosen)

- Stops where Gleam code itself said something is wrong, which is almost
  always interesting.
- Doesn't stop on expected crashes in supervised processes or on exits
  used for control flow, unless asked.

### B. Stop on every abnormal exit by default

- Catches FFI bugs and badmatches in Erlang code too.
- Noisy in OTP-style programs where processes are allowed to crash.

### C. No crash stops by default

- Matches ElixirLS, which has no exception breakpoints.
- A crash just ends the program, losing the very state you wanted to see.

### D. Stop at the raise, before the stack unwinds

- Would show the frame where the error happened, not just the crashed
  process's last state.
- `int` has no hook for that; it only reports the exit.

## Why

Gleam errors carry their message, module and line, so A gives a precise,
low-noise stop. The filters are standard DAP, so changing the default is a
checkbox in the editor.

## How to change it

The default list is `exception_filters` in `session.new_state`, and the
filters advertised in `initialize` (`src/gleam_dap/session.gleam`). The
attach-on-exit logic is in `gleam_dap_int_ffi:on_attach`.
