# What was left out?

**Already built (as cuts):** the following are not implemented, on purpose.
Each is documented in the README's known limitations.

## Where and when it came up

While implementing steps 2 to 5, whenever a feature would have cost much
more than its value for a first version of a personal tool.

## The cuts

### No `args` for the entry function

- The entry function is called with no arguments, like `gleam run` calls
  `main`. Gleam programs read their arguments with `argv`-style packages
  (which read `init:get_plain_arguments/0`), not through `main`'s
  parameters.
- **Alternative:** an `args` list passed to the function, or set as plain
  arguments of the adapter's VM so `argv` sees them. The second is the
  useful one, but plain arguments can't be changed after the VM started, so
  it would need starting the program in a new VM (see
  [09-packaging.md](09-packaging.md), option C).

### No Windows support

- The launcher is a shell script, the adapter talks DAP through a
  `{fd, 0, 1}` port, and paths are handled as POSIX paths. None of this
  has been tried on Windows.
- **Alternative:** a `gleam-dap.cmd` launcher and path normalisation. Worth
  doing once someone needs it and can test it.

### The Gleam version check only runs when building

- With `"build": false`, the adapter doesn't run `gleam --version`, so it
  can't tell whether the BEAM files came from Gleam 1.19 or newer. Old BEAM
  files then give wrong breakpoint lines rather than an error.
- **Alternative:** detect the compiler version from the BEAM files
  themselves (for example the presence of Gleam-line annotations). Not
  reliable enough to build on without more investigation.

### No paged variables

- See [17-value-rendering.md](17-value-rendering.md).

### Not hooking `echo`

- See [11-debug-break.md](11-debug-break.md).

## Why

None of these blocks the plan's goals, and each has a clear workaround.

## How to change it

Each item names its alternative; none of them requires undoing existing
code.
