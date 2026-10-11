# gleam_dap_debug

A `debug.break()` function that stops the current process in the
[gleam-dap](../../README.md) debugger, as if there were a breakpoint on the
next line. Outside the debugger it does nothing.

Add it as a path dependency (it is not published on Hex):

```toml
[dependencies]
gleam_dap_debug = { path = "../gleam-dap/packages/gleam_dap_debug" }
```

```gleam
import gleam_dap/debug

pub fn main() {
  let config = load_config()
  debug.break()
  run(config)
}
```

The calling module has to be interpreted by the debugger, which the
project's own modules are by default.
