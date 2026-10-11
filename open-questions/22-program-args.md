# How does the program get its `args`?

**Already built (PR #5):** a launch with a non-empty `args` makes the
adapter start a second adapter VM with `-extra <args...>`, send it the
original `initialize` and `launch` requests, and from then on relay every
message both ways. The program runs in that VM, where
`init:get_plain_arguments()` (and so `argv.load()`) returns the arguments.
`src/gleam_dap_relay_ffi.erl`, `start_relay` in
`src/gleam_dap/session.gleam`.

## Where and when it came up

Closing the gaps with ElixirLS, which passes `taskArgs` to the Mix task.
[19-scope-cuts.md](19-scope-cuts.md) had cut it from the first version for
the reason below.

## The problem

Gleam programs don't receive arguments through `main`; they read the VM's
plain arguments. Those are set when the VM starts and kept by the `init`
process, which has no way to change them. The adapter runs the program in
its own VM, which was started by the editor without them.

## Options

### A. A second adapter VM, relayed to (chosen)

- The program runs exactly as without `args`: same VM layout, same
  debugging, same tests. The parent only copies bytes and drops the
  child's duplicate `initialize` response.
- Works in both editors without changes to how they start the adapter.
- Costs a second VM start (about a second) and a little memory, only for
  launches that have `args`. Event `seq` numbers restart in the child;
  neither VS Code nor LSP4IJ checks them.

### B. Run the program on a separate node and attach to it

- Reuses attach mode instead of a relay.
- Attach has differences the user would notice for an ordinary launch:
  output capture, the threads view (process ancestry isn't visible across
  nodes), crash reporting, and node lifetime. Everything that works for
  launches would need re-testing in this mode.

### C. Let the editor pass the arguments to the adapter VM

- No second VM: the VS Code extension could start `erl ... -extra <args>`
  from the debug configuration.
- LSP4IJ starts the adapter with a fixed command, so IntelliJ couldn't use
  it.

### D. Patch `init` or intercept `init:get_plain_arguments/0`

- Not possible without replacing a preloaded system module.

## Why

A gives arguments to both editors without a second debugging mode to
maintain.

## How to change it

`program_args` in `src/gleam_dap/session.gleam` decides when to relay. The
child is recognised by its `-gleam_dap_child` flag, so it never relays
again.
