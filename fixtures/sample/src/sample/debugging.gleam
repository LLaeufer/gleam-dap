import gleam_dap/debug

@external(erlang, "sample_ffi", "println")
fn println(text: String) -> Nil

pub fn main() -> Nil {
  let before = "about to break"
  debug.break()
  println(before)
}
