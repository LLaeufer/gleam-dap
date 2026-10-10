import sample/flow
import sample/shapes.{Circle, Person, Rectangle}

@external(erlang, "sample_ffi", "println")
pub fn println(text: String) -> Nil

pub fn main() -> Nil {
  let x = 1
  let x = x + 1
  let greeting = greet("Ada")
  println(greeting)
  let person = Person(name: "Ada", age: 36)
  let older = shapes.birthday(person)
  let area = shapes.area(Circle(2.0)) +. shapes.area(Rectangle(1.0, 3.0))
  println(shapes.describe(older))
  let total = flow.pipes(x)
  let result = flow.with_use(total)
  let assert Ok(n) = result
  println(flow.classify(n))
  flow.spawn_worker()
  let _ = area
  Nil
}

pub fn greet(name: String) -> String {
  let prefix = "Hello, "
  prefix <> name <> "!"
}

pub fn crash_main() -> Nil {
  println("about to crash")
  let value = flow.with_use(-1)
  let assert Ok(n) = value
  println(flow.classify(n))
}

pub fn panic_main() -> Nil {
  let reason = "deliberate"
  panic as reason
}

pub fn loop_main() -> Nil {
  count_down(1_000_000_000)
}

fn count_down(n: Int) -> Nil {
  case n {
    0 -> Nil
    _ -> count_down(n - 1)
  }
}

/// Runs until stopped, calling into another module every few
/// milliseconds, for attaching to a running node.
pub fn serve_main() -> Nil {
  serve(0)
}

fn serve(n: Int) -> Nil {
  let _ = flow.double(n)
  sleep(20)
  serve(n + 1)
}

@external(erlang, "sample_ffi", "sleep")
fn sleep(ms: Int) -> Nil
