# Use `gleam_json`, `gleam_otp` and `glance`?

**Already built:** the adapter depends only on `gleam_stdlib` and
`gleam_erlang` (plus `gleeunit` for tests).

## Where and when it came up

PLAN.md's architecture section lists "likely dependencies: `gleam_stdlib`,
`gleam_erlang`, `gleam_otp` and `gleam_json`, plus possibly `glance`". It
came up in step 2 when writing the transport and the session.

## What I chose

- **JSON:** OTP 27's built-in `json` module through a small FFI
  (`gleam_dap_ffi:json_encode/json_decode`), with a Gleam `Json` type in
  `src/gleam_dap/json.gleam`.
- **Session process:** a plain process with a `gleam_erlang` `Subject` and a
  receive loop (`session.gleam`), not a `gleam_otp` actor.
- **Custom types:** no `glance`; see
  [03-custom-type-labels.md](03-custom-type-labels.md).

## Options

### A. Minimal dependencies (chosen)

- Every dependency is code the debugged program may also use, in another
  version, in the same VM. Fewer dependencies means less to isolate (see
  [09-packaging.md](09-packaging.md)) and a smaller adapter.
- OTP 27 is already required, so its `json` module is always there.
- The session needs selective receives from several sources (DAP input,
  `int` callbacks, monitors, worker results, timers); a hand-written loop
  over one `Subject` does that simply.
- A bit more FFI and hand-written JSON helpers.

### B. `gleam_json` and `gleam_otp` as planned

- Idiomatic Gleam; `gleam_json`'s decoders are nicer than the hand-rolled
  ones.
- Two more packages to rename and keep apart from the program's copies.
  `gleam_json` on Erlang wraps the same OTP `json` module anyway.
- `gleam_otp` actors add supervision the adapter doesn't need: if the
  session dies, the debug session is over regardless.

## Why

The adapter shares a VM with arbitrary user code, so every dependency is a
potential version clash. A gave the same features with less risk.

## How to change it

Add the packages to `gleam.toml`, replace `src/gleam_dap/json.gleam` with
`gleam_json` calls and `session.run`'s loop with an actor. The packaging
script renames any new dependency automatically.
