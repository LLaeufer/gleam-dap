# How does attach connect and detach?

**Already built:** an `attach` request with `node` (and optionally
`cookie`) turns the adapter into a distributed node with a random short name
(`gleam_dap_<n>`, falling back to long names), connects, and interprets the
project's modules on all connected nodes with `int:ni`. Disconnecting
resumes every paused process, removes all breakpoints and stops
interpreting, leaving the node as it was. "Terminate" (or disconnect with
`terminateDebuggee`) stops the node with `init:stop()`.

## Where and when it came up

Step 5 of PLAN.md: "Attach to a running node", with
[docs/elixirls-features.md](../docs/elixirls-features.md) describing
ElixirLS's approach. The open details came up when implementing it: how the
adapter becomes a node, what disconnect should leave behind, and what
terminate means for a node the adapter didn't start.

## What I chose

The behaviour above. `build` still defaults to `true` in the adapter for
both requests, but the attach snippets for VS Code and IntelliJ and the
README example set `"build": false`, so attaching doesn't rebuild the
project under a running node. (`int:ni` loads the interpreted code from the
BEAM files on disk, so a rebuild with changes would make the node run the
new code.)

## Options

### Name of the adapter's node

- **Random short name, long names as fallback (chosen):** works with the
  usual `erl -sname app` setups without configuration; two sessions never
  clash.
- **A configurable name:** needed only for unusual network setups; easy to
  add as an option later.

### Disconnect

- **Detach cleanly (chosen):** the node keeps running at full speed, with
  nothing interpreted and no breakpoints left behind. This is what "attach"
  usually promises.
- **Leave modules interpreted:** faster to re-attach, but the node stays
  slow and could stop on a stale breakpoint with nobody attached.

### Terminate

- **Stop the node (chosen):** DAP's terminate means "end the debuggee", and
  VS Code only sends it when the user explicitly picks terminate over
  disconnect.
- **Treat it like disconnect:** safer for production-like nodes, but then
  there's no way to end the node from the editor.

## Why

These match what DAP clients and ElixirLS users expect, and the end-to-end
tests check both paths (`attach_test` leaves nothing interpreted,
`terminate_attached_node_test` stops the node).

## How to change it

`connect_node` and `start_distribution` in `src/gleam_dap_launch_ffi.erl`,
`disconnect` and `stop_program` in `src/gleam_dap/session.gleam`, and
`stop_node`/`detach_all` in `src/gleam_dap_session_ffi.erl`.
