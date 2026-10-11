import gleam/dynamic.{type Dynamic}
import gleam/option.{Some}

@external(erlang, "test_ffi", "to_dynamic")
fn d(x: a) -> Dynamic

@external(erlang, "gleam_dap_eval_ffi", "eval")
fn eval(
  source: String,
  bindings: List(#(String, Dynamic)),
) -> Result(Dynamic, String)

@external(erlang, "gleam_dap_eval_ffi", "set_labels")
fn set_labels(labels: List(#(#(String, Int), #(String, List(String))))) -> Nil

@external(erlang, "gleam_dap_eval_ffi", "interpolate")
fn interpolate(message: String, bindings: List(#(String, Dynamic))) -> String

type Person {
  Person(name: String, age: Int)
}

pub fn gleam_variable_names_test() {
  let bindings = [#("X", d(1)), #("X@1", d(5))]
  assert eval("x * 2", bindings) == Ok(d(10))
}

pub fn gleam_literals_test() {
  assert eval("True", []) == Ok(d(True))
  assert eval("Nil", []) == Ok(d(Nil))
  assert eval("\"hi\"", []) == Ok(d("hi"))
}

pub fn gleam_operators_test() {
  let bindings = [#("N", d(3))]
  assert eval("n != 4 && n > 2", bindings) == Ok(d(True))
  assert eval("n == 4 || False", bindings) == Ok(d(False))
}

pub fn string_comparison_test() {
  assert eval("name == \"Ada\"", [#("Name", d("Ada"))]) == Ok(d(True))
}

pub fn string_concat_test() {
  let bindings = [#("Name", d("Ada"))]
  assert eval("\"Hello, \" <> name <> \"!\"", bindings) == Ok(d("Hello, Ada!"))
  assert eval("[1] <> [2]", []) == Ok(d([1, 2]))
  assert eval("<<>> == \"\"", []) == Ok(d(True))
}

pub fn field_access_test() {
  set_labels([#(#("person", 2), #("Person", ["name", "age"]))])
  let bindings = [#("P", d(Person("Ada", 36))), #("Pair", d(#(1, Some(2))))]
  assert eval("p.age + 1", bindings) == Ok(d(37))
  assert eval("pair.1", bindings) == Ok(d(Some(2)))
}

pub fn module_calls_test() {
  assert eval("erlang.length(xs)", [#("Xs", d([1, 2, 3]))]) == Ok(d(3))
}

pub fn unknown_variable_test() {
  assert eval("nope", []) == Error("Unknown variable nope")
}

pub fn syntax_error_test() {
  let assert Error(_) = eval("1 +", [])
}

pub fn interpolate_test() {
  assert interpolate("x is {x}, {y}!", [#("X", d([1])), #("Y", d("a"))])
    == "x is [1], \"a\"!"
}
