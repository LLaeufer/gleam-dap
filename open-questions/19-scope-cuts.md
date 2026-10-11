# What was left out?

**Already built (as cuts):** the following are not implemented, on purpose.
Each is documented in the README's known limitations.

## Where and when it came up

While implementing steps 2 to 5, whenever a feature would have cost much
more than its value for a first version of a personal tool.

## The cuts

### `args` and Windows (no longer cut)

Both were cut from PR #4 and built in PR #5: see
[22-program-args.md](22-program-args.md) and [25-windows.md](25-windows.md).

### The Gleam version check only runs when building

- With `"build": false`, the adapter doesn't run `gleam --version`, so it
  can't tell whether the BEAM files came from Gleam 1.19 or newer. Old BEAM
  files then give wrong breakpoint lines rather than an error.
- **Alternative:** detect the compiler version from the BEAM files
  themselves (for example the presence of Gleam-line annotations). Not
  reliable enough to build on without more investigation.

### Paged variables (no longer cut)

- Built in PR #5, see [21-paging.md](21-paging.md).

### Not hooking `echo`

- See [11-debug-break.md](11-debug-break.md).

## Why

None of these blocks the plan's goals, and each has a clear workaround.

## How to change it

Each item names its alternative; none of them requires undoing existing
code.
