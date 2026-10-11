# How does `target: "test"` run tests?

**Already built:** with `"target": "test"` and no `module`, the adapter
runs `eunit:test([<every project module ending in _test>], [verbose])` in
the program process. With `module` set, it calls that module's `function`
(default `main`) like a normal launch.

## Where and when it came up

[docs/elixirls-features.md](../docs/elixirls-features.md) says "debugging
tests works anyway with `target: test`" without saying how. It came up when
implementing launch options in step 2.

## What I chose

Call EUnit directly on the test modules, which is what gleeunit's `main`
does on the Erlang target.

## Options

### A. EUnit on every `*_test` module (chosen)

- Works for gleeunit projects (the default for `gleam new`) without running
  gleeunit's own `main`, whose module discovery reads the file system
  relative to the working directory.
- Test output appears in the debug console.
- Projects using another test runner need `module` and `function` set.

### B. Run the project's `<name>_test.main()`

- Exactly what `gleam test` runs.
- gleeunit's `main` halts the VM when done, which would kill the adapter
  with it.

### C. Shell out to `gleam test`

- Identical to the command line.
- Runs in another VM, which the adapter can't debug without attaching.

## Why

A behaves like `gleam test` for gleeunit projects, inside the debugged VM,
and doesn't halt the adapter.

## How to change it

`start_program` in `src/gleam_dap/session.gleam` and `eunit_args` in
`src/gleam_dap_launch_ffi.erl`.
