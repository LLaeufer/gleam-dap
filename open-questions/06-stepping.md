# What exactly do step over and step out do in Gleam code?

**Already built:** `src/gleam_dap/stepping.gleam`, driven by the session's
`next` handler; step in and step out map to `int`'s `step` and `finish`.

## Where and when it came up

PLAN.md says step over must be "corrected for tail calls". While building it
on the fixture, two more cases showed up: the callback of a `use` runs one
call level deeper, so `int`'s plain `next` skipped the rest of the function
after a `use` line; and lambdas passed on the same line
(`list.map(xs, fn(x) { ... })`) could either be stepped through or stopped
in.

## What I chose

Step over:

1. Normally issue `int:next`. When the current line defines an anonymous
   function (a `use` line, or a `fn` passed as an argument), single-step
   instead, because the code that comes "next" in the source may run inside
   that function.
2. After each stop, stop for real when:
   - back in the starting function on the starting level (including a
     tail call of itself),
   - in an anonymous function defined in the starting function, on a
     different line than the step started on (the body of a `use` callback),
   - returned to a caller,
   - at a breakpoint,
   - or after 2,000 single steps (a safety net).
3. In some other function on the starting level, that function was
   tail-called: issue `finish` to run it to the end (unless single-stepping,
   because then a callback of ours may still run inside it).
4. Deeper, keep single-stepping.

Step out is `int:finish`, which stops at the caller's next statement.

## Options

### A. The algorithm above (chosen)

- Stepping over a `use` line goes into the callback's body, which is the
  next line in the source; that is what people expect from reading the code.
- Tail calls are stepped over in both stack trace modes.
- Lambdas on the same line run through without stopping, like any other
  call on that line.
- Single-stepping is slower than `next` on lines that define a function and
  call a lot (each step is a round trip to the interpreter).
- Breakpoints in the code being stepped over are skipped, as `int` doesn't
  check them during `next` and `finish`. Single-stepping does see them.

### B. Plain `int:next` and `int:finish`

- Simple and fast.
- After a `use` line the step jumps out of the function entirely; with
  `no_tail` it stops inside tail-called functions. Both feel broken in
  idiomatic Gleam.

### C. Always single-step and decide after every step

- Breakpoints inside stepped-over calls would be hit, fixing the limitation
  of A.
- Every step over a call that does real work takes thousands of round trips;
  stepping over `list.map` on a long list could take seconds.

### D. Step over by setting temporary breakpoints on the following lines

- How many debuggers do it; also hits user breakpoints in between.
- Needs the set of lines that can come next, including inside `use`
  callbacks and `case` branches, and cleaning up the breakpoints in every
  process that might hit them.

## Why

A is correct for every construct in the fixture (functions, `case`, `use`,
pipelines, lambdas, recursion, both stack modes; see the stepping tests in
`test/integration_test.gleam` and `test/stepping_test.gleam`) and stays fast
in the common case. The breakpoint-skipping limitation is documented in the
README.

## How to change it

`stepping.decide` holds all the rules; C is `start` always returning `Step`
and `decide` never returning `Finish`. The step limit is
`stepping.step_limit`.
