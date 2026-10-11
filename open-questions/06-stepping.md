# What exactly do step over and step out do in Gleam code?

**Already built:** step over and step out run on temporary breakpoints
(`stepping.over_targets`/`out_targets` in `src/gleam_dap/stepping.gleam`,
`start_targeted` in `src/gleam_dap/session.gleam`, and the condition check in
`src/gleam_dap_eval_ffi.erl`), also when attached to a node (see
[24-attach-conditions.md](24-attach-conditions.md)). With
`stackTraceMode: "false"` they fall back to `int`'s own `next` and `finish`
with the tail-call corrections described under option B. Step in is
`int:step`.

## Where and when it came up

PLAN.md says step over must be "corrected for tail calls". While building it
on the fixture, two more cases showed up: the callback of a `use` runs one
call level deeper, so `int`'s plain `next` skipped the rest of the function
after a `use` line; and lambdas passed on the same line
(`list.map(xs, fn(x) { ... })`) could either be stepped through or stopped
in. The first version (option B) had one limitation Leonie asked about on
11 October: a breakpoint inside a function being stepped over never stopped,
because `int` only checks breakpoints at levels no deeper than the one a
`next` or `finish` waits for (`dbg_icmd:cmd/4` in OTP's debugger). That led
to option A.

## What I chose

A step over from line L of function F at call level N puts a temporary
breakpoint on:

- every line of F, firing only at level N or higher up (so recursive calls
  of F run through);
- the lines of anonymous functions nested in F deeper than L's own nesting,
  such as the callback of a `use` on L, firing at any level because they run
  inside the calls; lambdas on L itself run through;
- every line of each caller on the stack (up to 50 frames), firing at that
  caller's level, for when F returns.

Then the process simply continues. Each temporary breakpoint has a condition
that fires only in the stepping process and checks its current call level,
which the condition reads from the interpreter's process dictionary
(`get(self)` and `dbg_istk:stack_level()`; the condition runs in the
interpreter's process for the program process). Breakpoints of the user's
stop the process on the way, with reason `breakpoint`; the step's own targets
stop it with reason `step`. Step out does the same with only the callers'
lines. When the process stops for any reason, its temporary breakpoints are
removed.

## Options

### A. Temporary breakpoints plus continue (chosen)

- Breakpoints, conditions and logpoints inside the code being stepped over
  or out of work, because the process runs normally.
- Stepping over a call runs at full speed, however much work the call does.
- `use` callbacks, tail calls and recursion behave as in option B (the same
  tests pass with both).
- Other processes running the same lines evaluate a cheap condition (two ETS
  lookups) and carry on.
- Relies on two internals of OTP's debugger: that conditions run in the
  interpreter's process for the program process, where `self` holds that
  process, and `dbg_istk:stack_level/0`. Both have been stable for many OTP
  releases; the end-to-end tests would catch a change.
- Each step adds and removes `int` breakpoints, a few dozen calls to the
  debugger's server.
- Not available without a call stack (`stackTraceMode: "false"`). When
  attached, the conditions run on the other node and call back to the
  adapter, which costs a network round trip per line reached that has a
  temporary breakpoint (see [24-attach-conditions.md](24-attach-conditions.md)).

### B. `int`'s `next`/`finish` with corrections (the first version, now the fallback)

1. Normally issue `int:next`. When the current line defines an anonymous
   function, single-step instead, because the code that comes "next" in the
   source may run inside that function.
2. After each stop, stop for real when back in the starting function on the
   starting level, in an anonymous function defined in it on another line,
   back in a caller, at a breakpoint, or after 2,000 single steps.
3. In some other function on the starting level, that function was
   tail-called: issue `finish` to run it to the end.

- No internals beyond `int`'s public API.
- Breakpoints inside the calls being stepped over are skipped.

### C. Always single-step and decide after every step

- Sees every breakpoint, with only public API.
- Every step over a call that does real work takes thousands of round trips;
  stepping over `list.map` on a long list could take seconds, and a step
  limit would cut long calls short.

### D. Plain `int:next` and `int:finish`

- Simplest.
- After a `use` line the step jumps out of the function; with `no_tail` it
  stops inside tail-called functions; breakpoints inside calls are skipped.

## Why

A is the only option that stops at breakpoints inside stepped-over calls
without making steps slow. The internals it relies on are small and covered
by tests (`step_over_stops_at_breakpoints_inside_test`, its `no_tail`
variant, and `step_out_stops_at_breakpoints_on_the_way_test`, which fail with
option B).

## How to change it

To go back to B everywhere, make `targeted_steps` in
`src/gleam_dap/session.gleam` return `False`. The target rules are
`stepping.over_targets` and `stepping.out_targets`; B's rules are
`stepping.decide`.
