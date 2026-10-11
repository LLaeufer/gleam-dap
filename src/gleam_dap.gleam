//// gleam-dap: a Debug Adapter Protocol debugger for Gleam on the Erlang VM.
////
//// The adapter talks DAP on stdio and runs the program being debugged in
//// its own VM, interpreted by Erlang's `int`.

import gleam_dap/log
import gleam_dap/session

pub fn main() -> Nil {
  case get_env("GLEAM_DAP_LOG") {
    Ok(path) -> log.open(path)
    Error(Nil) -> Nil
  }
  session.run()
}

@external(erlang, "gleam_dap_launch_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)
