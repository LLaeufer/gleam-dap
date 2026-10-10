# What happens to breakpoints in modules that aren't interpreted?

**Already built:** such breakpoints come back unverified, with the message
"<module> is not interpreted. Add it to interpretModules in the launch
configuration to debug it." A file that belongs to no known module says
there's no code for it.

## Where and when it came up

Step 4, when setting a breakpoint in a dependency's source (opened through
"Go to definition" into `build/packages/...`) during a session that only
interprets the project's own modules.

## What I chose

Refuse with a message that names the fix.

## Options

### A. Refuse with a hint (chosen)

- The editor shows the breakpoint as unverified with the reason on hover,
  so it's clear why it won't stop and what to change.
- Takes a restart with a changed launch configuration to debug that module.

### B. Interpret the module on demand

- Just works: set a breakpoint anywhere and it stops.
- What ElixirLS does: it interprets the files' modules when a breakpoint is
  set in them (see [docs/elixirls-features.md](../docs/elixirls-features.md),
  "Line breakpoints").
- Interpreting a module while the program runs swaps code under processes
  that are already executing it; modules the adapter itself uses must still
  be refused (see [09-packaging.md](09-packaging.md)); and the program
  silently becomes slower in ways the user didn't choose, for example after
  a stray click in a `gleam_stdlib` file.

### C. Accept silently and never stop

- What ElixirLS does for blank lines: the breakpoint looks fine and never
  fires, which is the most confusing outcome.

## Why

A is honest and cheap, and the hint makes the fix a one-line change. B is
the friendlier option if the slowdown and the occasional code swap don't
bother you; it's a small change.

## How to change it

`set_breakpoints` and the `not_interpreted` message in
`src/gleam_dap/session.gleam`. B would call `launch.interpret` for the
module there, after checking `loaded_elsewhere`.
