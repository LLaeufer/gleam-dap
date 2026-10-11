# What happens to breakpoints in modules that aren't interpreted?

**Already built:** option B since PR #5 (it was option A before). A line or
function breakpoint in a module that isn't interpreted interprets it on the
spot, like ElixirLS. Two cases are still refused, with the reason on the
breakpoint: modules matching `excludeModules`, and modules the adapter runs
itself (`loaded_elsewhere`; from a source checkout that includes
`gleam_stdlib`, from a packaged build nothing of the program's). A file that
belongs to no known module says there's no code for it.

## Where and when it came up

Step 4, when setting a breakpoint in a dependency's source (opened through
"Go to definition" into `build/packages/...`) during a session that only
interprets the project's own modules.

## What I chose

Refuse with a message that names the fix.

## Options

### A. Refuse with a hint (the first version)

- The editor shows the breakpoint as unverified with the reason on hover,
  so it's clear why it won't stop and what to change.
- Takes a restart with a changed launch configuration to debug that module.

### B. Interpret the module on demand (chosen)

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

A was honest and cheap. B was built when closing the gaps with ElixirLS:
setting a breakpoint is a clear enough sign that the user wants that module
debugged, and `excludeModules` is there for modules that must never be
interpreted. The code swap is harmless for Gleam code (processes already
inside the module finish their current call compiled), and the slowdown is
limited to the modules the user put breakpoints in.

Interpreting is permanent for the session: removing the breakpoint leaves
the module interpreted. Un-interpreting on removal would make the module
fast again, but would also throw away any other breakpoints' effect and
swap code a second time; it didn't seem worth it.

## How to change it

`ensure_interpreted` in `src/gleam_dap/session.gleam` (called from
`set_breakpoints` and `set_function_breakpoints`) and
`launch.can_interpret_later`. To go back to A, return
`Error(...)` from `ensure_interpreted` instead of interpreting.
