//// Adapter logs. They go to a file, never to stdout, which carries DAP.
//// The file is `$GLEAM_DAP_LOG`, if set.

import gleam/string

@external(erlang, "gleam_dap_ffi", "log_open")
pub fn open(path: String) -> Nil

@external(erlang, "gleam_dap_ffi", "log")
pub fn info(message: String) -> Nil

pub fn debug(label: String, value: a) -> Nil {
  info(label <> ": " <> string.inspect(value))
}
