//// Stop in the gleam-dap debugger from code.
////
//// ```gleam
//// import gleam_dap/debug
////
//// pub fn main() {
////   let config = load_config()
////   debug.break()
////   run(config)
//// }
//// ```

/// Stops the current process in the debugger at the next line, as if there
/// were a breakpoint there.
///
/// Does nothing when the program isn't running under gleam-dap, or when the
/// calling module isn't interpreted by the debugger.
@external(erlang, "gleam_dap_debug_ffi", "break")
pub fn break() -> Nil
