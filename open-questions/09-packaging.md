# How to keep the adapter's stdlib apart from the program's?

**Already built:** `scripts/package.escript` renames every module of the
adapter's dependencies to `gleam_dap@vendor@<module>` (for example
`gleam_dap@vendor@gleam@list`) by rewriting their abstract code, and writes
the result to `dist/gleam-dap`. The VS Code extension bundles the same
package.

## Where and when it came up

PLAN.md says to ship the adapter as an Erlang shipment and that the adapter
must never interpret the modules it uses itself;
[docs/elixirls-features.md](../docs/elixirls-features.md) concludes that the
adapter's dependencies (`gleam_stdlib`, `gleam_erlang`, ...) therefore can't
be interpreted "unless the user explicitly asks for them". It came up in step
4 when the packaged adapter and the debugged program both loaded
`gleam@list`: only one copy of a module can be loaded in a VM, so the program
would silently run the adapter's version (or the other way round), and
interpreting it would deadlock the adapter at the first breakpoint in it.

## What I chose

Rename the dependencies inside the package. The program's own
`gleam_stdlib` then loads normally, in whatever version it wants, and can be
interpreted (`"interpretModules": ["gleam/list"]`) without the adapter ever
running interpreted code. As a second guard, `launch.modules_to_interpret`
never interprets a module whose loaded copy isn't the project's
(`loaded_elsewhere`), which covers running the adapter unpackaged from
source.

## Options

### A. Rename the adapter's dependencies when packaging (chosen)

- No version clashes, and users can debug into the standard library.
- A build step that rewrites BEAM files; atoms that name dependency modules
  dynamically (as opposed to in calls and `fun M:F/A`) would be missed. None
  of the current dependencies do that, and the end-to-end tests run against
  the package in CI to catch it.
- Running from source (`gleam run`) doesn't get the renaming; that's only
  used for development.

### B. Never interpret the adapter's dependencies

- What the plan describes. No build magic.
- The program runs the adapter's version of `gleam_stdlib`, not its own,
  which can break programs that need a different version, and
  `interpretDependencies` can't cover the standard library.

### C. Run the program in a separate node

- Perfect isolation, and the adapter could survive the program crashing the
  VM.
- Needs distributed Erlang for every launch, `int:ni` on the other node,
  and forwarding of stdio; startup is slower and more fragile. The plan
  chose the same VM on purpose.

### D. Write the adapter without dependencies

- Nothing to clash.
- Gives up `gleam_stdlib` in the adapter itself, which is most of what makes
  writing it in Gleam pleasant.

## Why

A removes the clash completely at the cost of one build script, keeping the
plan's same-VM design.

## How to change it

B: stop renaming in `scripts/package.escript` (copy the shipment's ebin
folders as they are) and add the dependency modules to an exclusion list in
`launch.modules_to_interpret`. The prefix is the `PREFIX` macro in the
script.
