import sample/shapes

@external(erlang, "sample_ffi", "spawn")
fn spawn(f: fn() -> Nil) -> a

pub fn double(x: Int) -> Int {
  x * 2
}

pub fn pipes(x: Int) -> Int {
  x
  |> double
  |> double
}

fn try(value: Result(a, e), next: fn(a) -> Result(b, e)) -> Result(b, e) {
  case value {
    Ok(v) -> next(v)
    Error(e) -> Error(e)
  }
}

pub fn with_use(x: Int) -> Result(Int, String) {
  use y <- try(check(x))
  let z = y + 1
  Ok(z * 10)
}

fn check(x: Int) -> Result(Int, String) {
  case x {
    _ if x < 0 -> Error("negative")
    _ -> Ok(x)
  }
}

pub fn classify(n: Int) -> String {
  let label = case n {
    0 -> "zero"
    n if n < 10 -> "small"
    _ -> "big"
  }
  let items = [1, 2, 3] |> map(fn(i) { i * n })
  let pair = #(label, items)
  let total =
    double(1)
    + double(2)
  case pair, total {
    #(l, _), 6 -> l
    _, _ -> "unexpected"
  }
}

fn map(list: List(a), f: fn(a) -> b) -> List(b) {
  case list {
    [] -> []
    [first, ..rest] -> [f(first), ..map(rest, f)]
  }
}

pub fn spawn_worker() -> Nil {
  let _ = spawn(fn() { worker(shapes.Just(42)) })
  Nil
}

fn worker(input: shapes.Maybe(Int)) -> Nil {
  let value = case input {
    shapes.Just(v) -> v
    shapes.Nothing -> 0
  }
  let _ = value
  Nil
}
